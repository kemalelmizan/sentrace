module Sentrace
  module Mcp
    class EnvironmentRouter
      MUTATION_OPERATIONS = %i[update_issue_status].freeze
      MAX_FEDERATED_CONCURRENCY = 8

      def initialize(config: Sentrace.configuration, remote_client: RemoteHttpClient.new)
        @config = config
        @remote_client = remote_client
      end

      def list_environments
        env_defs = @config.environments.values
        use_threads = env_defs.size > 1

        envs = if use_threads
          run_bounded_threads(env_defs) do |target|
            build_environment_entry(target, in_worker_thread: true)
          end
        else
          env_defs.map { |env_def| build_environment_entry(env_def, in_worker_thread: false) }
        end

        { "environments" => envs }
      end

      def route(operation, environment: nil, **kwargs)
        op_sym = operation.to_sym
        is_mutation = MUTATION_OPERATIONS.include?(op_sym)
        targets = resolve_target_environments(environment, mutation: is_mutation)

        if is_mutation
          read_only_target = targets.find(&:read_only)
          if read_only_target
            raise McpForbiddenError,
              "Environment '#{read_only_target.name}' is configured as read-only and cannot invoke '#{op_sym}'"
          end
        end

        if targets.one? && !multi_environment_request?(environment)
          execute_single(targets.first, op_sym, **kwargs)
        else
          execute_federated(targets, op_sym, **kwargs)
        end
      end

      private
        def multi_environment_request?(environment)
          environment.to_s.strip.casecmp("all").zero?
        end

        def resolve_target_environments(environment, mutation:)
          env_map = @config.environments
          raw = environment.to_s.strip

          if raw.empty?
            default_env = env_map[:local] || env_map.values.first
            raise McpInvalidParamsError, "No environments configured" unless default_env

            [ default_env ]
          elsif raw.casecmp("all").zero?
            if mutation
              raise McpInvalidParamsError, "Mutations cannot target 'all' environments; specify an explicit environment"
            end

            env_map.values
          else
            target = env_map[raw.to_sym]
            unless target
              available = env_map.keys.map(&:to_s).join(", ")
              raise McpInvalidParamsError, "Unknown environment #{raw.inspect} (configured: #{available})"
            end

            [ target ]
          end
        end

        def execute_single(env_def, op_sym, in_worker_thread: false, **kwargs)
          case env_def.transport
          when :local
            if in_worker_thread
              ActiveRecord::Base.connection_pool.with_connection do
                LocalBackend.new(environment_name: env_def.name).public_send(op_sym, **kwargs)
              end
            else
              LocalBackend.new(environment_name: env_def.name).public_send(op_sym, **kwargs)
            end
          when :http
            unless @remote_client
              raise McpRemoteError.new(
                "Remote HTTP federation client is not configured for environment #{env_def.name}",
                environment: env_def.name,
                category: "transport_unavailable"
              )
            end
            @remote_client.call_environment(env_def, op_sym, **kwargs)
          else
            raise McpInvalidParamsError, "Unsupported transport #{env_def.transport.inspect}"
          end
        end

        def execute_federated(targets, op_sym, **kwargs)
          outcomes = run_bounded_threads(targets) do |target|
            payload = execute_single(target, op_sym, in_worker_thread: true, **kwargs)
            { ok: true, env_name: target.name.to_s, payload: payload }
          rescue McpRemoteError => e
            {
              ok: false,
              error: {
                "environment" => e.environment,
                "category" => e.category,
                "message" => e.message
              }
            }
          rescue McpNotFoundError => e
            {
              ok: false,
              error: {
                "environment" => target.name.to_s,
                "category" => "not_found",
                "message" => e.message
              }
            }
          rescue McpInvalidParamsError => e
            {
              ok: false,
              error: {
                "environment" => target.name.to_s,
                "category" => "invalid_params",
                "message" => e.message
              }
            }
          rescue StandardError => e
            {
              ok: false,
              error: {
                "environment" => target.name.to_s,
                "category" => "internal_error",
                "message" => "Failed querying environment #{target.name}: #{e.class}"
              }
            }
          end

          merge_outcomes(targets, op_sym, outcomes, **kwargs)
        end

        def run_bounded_threads(items, &block)
          return [] if items.empty?

          results = Array.new(items.size)
          queue = Queue.new
          items.each_with_index { |item, idx| queue << [ item, idx ] }

          worker_count = [ items.size, MAX_FEDERATED_CONCURRENCY ].min
          workers = Array.new(worker_count) do
            Thread.new do
              Thread.current.report_on_exception = false
              loop do
                pair = begin
                  queue.pop(true)
                rescue ThreadError
                  nil
                end
                break unless pair

                item, idx = pair
                results[idx] = block.call(item)
              end
            end
          end

          workers.each(&:join)
          results
        end

        def merge_outcomes(targets, op_sym, outcomes, **kwargs)
          successes = outcomes.select { |o| o[:ok] }.map { |o| stamp_payload_items(o[:payload], o[:env_name]) }
          errors = outcomes.reject { |o| o[:ok] }.map { |o| o[:error] }

          base = {
            "environment" => "all",
            "environments_queried" => targets.map { |t| t.name.to_s },
            "errors" => errors
          }

          case op_sym
          when :list_projects
            base.merge("projects" => successes.flat_map { |p| Array(p["projects"]) })
          when :list_issues
            merged_issues = successes.flat_map { |p| Array(p["issues"]) }
            sorted_issues = merged_issues.sort_by { |i| [ i["last_seen_at"].to_s, i["id"].to_i ] }.reverse
            sorted_issues = apply_optional_limit(sorted_issues, kwargs[:limit])
            base.merge(
              "untrusted_telemetry_notice" => LocalBackend::UNTRUSTED_TELEMETRY_NOTICE,
              "issues" => sorted_issues,
              "fingerprint_correlations" => build_fingerprint_correlations(merged_issues)
            )
          when :list_events
            merged_events = successes.flat_map { |p| Array(p["events"]) }
            sorted_events = merged_events.sort_by { |ev| [ ev["occurred_at"].to_s, ev["id"].to_i ] }.reverse
            sorted_events = apply_optional_limit(sorted_events, kwargs[:limit])
            base.merge(
              "untrusted_telemetry_notice" => LocalBackend::UNTRUSTED_TELEMETRY_NOTICE,
              "events" => sorted_events
            )
          when :get_error_trends
            series = successes.map do |p|
              {
                "environment" => p["environment"],
                "interval" => p["interval"],
                "since" => p["since"],
                "until" => p["until"],
                "total_events" => p["total_events"].to_i,
                "buckets" => Array(p["buckets"])
              }
            end
            base.merge(
              "total_events" => series.sum { |s| s["total_events"] },
              "series" => series
            )
          when :get_issue
            matches = successes.filter_map do |p|
              next unless p["issue"].is_a?(Hash)

              { "environment" => p["environment"], "issue" => p["issue"] }
            end
            base.merge(
              "untrusted_telemetry_notice" => LocalBackend::UNTRUSTED_TELEMETRY_NOTICE,
              "matches" => matches
            )
          when :get_event
            matches = successes.filter_map do |p|
              next unless p["event"].is_a?(Hash)

              { "environment" => p["environment"], "event" => p["event"] }
            end
            base.merge(
              "untrusted_telemetry_notice" => LocalBackend::UNTRUSTED_TELEMETRY_NOTICE,
              "matches" => matches
            )
          else
            base.merge("results" => successes)
          end
        end

        def stamp_payload_items(payload, target_env)
          return {} unless payload.is_a?(Hash)

          normalized = payload.merge("environment" => target_env)

          %w[projects issues events].each do |collection_key|
            next unless normalized[collection_key].is_a?(Array)

            normalized[collection_key] = normalized[collection_key].map do |item|
              item.is_a?(Hash) ? item.merge("environment" => target_env) : item
            end
          end

          %w[issue event].each do |record_key|
            next unless normalized[record_key].is_a?(Hash)

            normalized[record_key] = normalized[record_key].merge("environment" => target_env)
          end

          normalized
        end

        def build_fingerprint_correlations(issues)
          grouped = issues.select { |i| i.is_a?(Hash) && !i["fingerprint"].to_s.empty? }.group_by { |i| i["fingerprint"] }

          grouped.filter_map do |fingerprint, group|
            envs = group.map { |i| i["environment"].to_s }.reject(&:empty?).uniq
            next if envs.size < 2

            representative = select_correlation_representative(group)
            {
              "fingerprint" => fingerprint,
              "exception_type" => representative["exception_type"],
              "message" => representative["message"],
              "environments" => envs,
              "total_event_count" => group.sum { |i| i["event_count"].to_i },
              "issue_ids_by_environment" => group.each_with_object({}) do |item, acc|
                acc[item["environment"].to_s] = item["id"]
              end
            }
          end
        end

        def select_correlation_representative(group)
          prod_items = group.select { |item| item["environment"].to_s.casecmp("production").zero? }
          candidates = prod_items.any? ? prod_items : group
          candidates.max_by { |item| [ item["last_seen_at"].to_s, item["id"].to_i ] } || group.first
        end

        def apply_optional_limit(items, raw_limit)
          return items if raw_limit.nil?

          parsed = Integer(raw_limit.to_s, 10)
          parsed.positive? ? items.first([ parsed, LocalBackend::MAX_LIMIT ].min) : items
        rescue ArgumentError, TypeError
          items
        end

        def build_environment_entry(env_def, in_worker_thread:)
          safe_url = env_def.url ? Ingestion::Sanitizer.sanitize_url(env_def.url) : nil
          {
            "name" => env_def.name.to_s,
            "transport" => env_def.transport.to_s,
            "url" => safe_url,
            "timeout" => env_def.timeout,
            "status" => environment_status(env_def, in_worker_thread: in_worker_thread)
          }.compact
        end

        def environment_status(env_def, in_worker_thread: false)
          case env_def.transport
          when :local
            if in_worker_thread
              ActiveRecord::Base.connection_pool.with_connection do
                LocalBackend.new(environment_name: env_def.name).connection_status
              end
            else
              LocalBackend.new(environment_name: env_def.name).connection_status
            end
          when :http
            return "unconfigured" if env_def.url.to_s.strip.empty? || env_def.token.to_s.strip.empty?
            if @remote_client
              ping_timeout = resolve_ping_timeout(env_def)
              return @remote_client.environment_status(env_def, timeout: ping_timeout)
            end

            "configured"
          else
            "unknown"
          end
        rescue StandardError
          "unreachable"
        end

        def resolve_ping_timeout(env_def)
          return env_def.timeout unless @config.respond_to?(:remote_ping_timeout) && @config.remote_ping_timeout

          [ env_def.timeout, @config.remote_ping_timeout ].min
        end
    end
  end
end
