module Sentrace
  module Mcp
    class Dispatcher
      MUTATION_OPERATIONS = %i[update_issue_status].freeze

      def initialize(config: Sentrace.configuration, remote_client: nil)
        @config = config
        @remote_client = remote_client
      end

      def list_environments
        envs = @config.environments.values.map do |env_def|
          {
            "name" => env_def.name.to_s,
            "transport" => env_def.transport.to_s,
            "url" => env_def.url,
            "timeout" => env_def.timeout,
            "status" => environment_status(env_def)
          }.compact
        end

        { "environments" => envs }
      end

      def dispatch(operation, environment: nil, **kwargs)
        op_sym = operation.to_sym
        targets = resolve_target_environments(environment, mutation: MUTATION_OPERATIONS.include?(op_sym))

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

        def execute_single(env_def, op_sym, **kwargs)
          case env_def.transport
          when :local
            LocalBackend.new(environment_name: env_def.name).public_send(op_sym, **kwargs)
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
          results = []
          errors = []

          targets.each do |env_def|
            results << execute_single(env_def, op_sym, **kwargs)
          rescue McpRemoteError => e
            errors << {
              "environment" => e.environment,
              "category" => e.category,
              "message" => e.message
            }
          rescue McpNotFoundError => e
            errors << {
              "environment" => env_def.name.to_s,
              "category" => "not_found",
              "message" => e.message
            }
          rescue StandardError => e
            errors << {
              "environment" => env_def.name.to_s,
              "category" => "internal_error",
              "message" => "Failed querying environment #{env_def.name}: #{e.class}"
            }
          end

          {
            "environments_queried" => targets.map { |t| t.name.to_s },
            "results" => results,
            "errors" => errors
          }
        end

        def environment_status(env_def)
          case env_def.transport
          when :local
            LocalBackend.new(environment_name: env_def.name).connection_status
          when :http
            return "unconfigured" if env_def.url.to_s.strip.empty?
            return @remote_client.environment_status(env_def) if @remote_client

            "configured"
          else
            "unknown"
          end
        end
    end
  end
end
