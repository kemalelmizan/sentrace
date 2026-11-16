require "erb"

module Sentrace
  module ViewHelpers
    def sentrace_meta_tags(
      dsn: Sentrace.configuration.frontend_dsn,
      project: nil,
      environment: Sentrace.configuration.deployment_environment,
      release: Sentrace.configuration.release,
      request_id: :auto
    )
      return html_safe_string("") unless Sentrace.configuration.enabled

      public_dsn = resolve_public_frontend_dsn(dsn: dsn, project: project)
      return html_safe_string("") if public_dsn.nil? || public_dsn.empty?

      resolved_request_id =
        if request_id == :auto
          respond_to?(:request) && request.respond_to?(:request_id) ? request.request_id : nil
        else
          request_id
        end

      tags = [ meta_tag_html("sentrace-dsn", public_dsn) ]
      tags << meta_tag_html("sentrace-environment", environment) unless blank_value?(environment)
      tags << meta_tag_html("sentrace-release", release) unless blank_value?(release)
      tags << meta_tag_html("sentrace-request-id", resolved_request_id) unless blank_value?(resolved_request_id)

      html_safe_string(tags.join("\n"))
    end

    private
      def resolve_public_frontend_dsn(dsn:, project:)
        raw_dsn = dsn.to_s.strip
        if !raw_dsn.empty?
          return Dsn.parse(raw_dsn).without_secret.to_s
        end

        return nil if blank_value?(project)

        record = find_sentrace_project(project)
        return nil unless record

        base_url = infer_sentrace_base_url
        return nil unless base_url

        Dsn.parse(record.dsn(base_url: base_url).to_s).without_secret.to_s
      rescue InvalidDsnError
        nil
      end

      def find_sentrace_project(project_ref)
        return project_ref if project_ref.is_a?(Project)

        str = project_ref.to_s.strip
        if str.match?(/\A\d+\z/)
          Project.find_by(id: Integer(str, 10))
        else
          Project.find_by(slug: str.downcase)
        end
      end

      def infer_sentrace_base_url
        base = respond_to?(:request) && request.respond_to?(:base_url) ? request.base_url.to_s : ""
        return nil if base.empty?

        mount_path = detect_engine_mount_path
        "#{base.chomp('/')}#{mount_path}"
      end

      def detect_engine_mount_path
        return "/sentrace" unless defined?(Rails) && Rails.application

        mounted = Rails.application.routes.routes.find do |route|
          app = route.app
          target = app.respond_to?(:app) ? app.app : app
          target == Sentrace::Engine
        end
        return "" unless mounted

        mounted.path.spec.to_s.chomp("/")
      end

      def meta_tag_html(name, content)
        escaped_name = ERB::Util.html_escape(name.to_s)
        escaped_content = ERB::Util.html_escape(content.to_s)
        %(<meta name="#{escaped_name}" content="#{escaped_content}">)
      end

      def blank_value?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def html_safe_string(value)
        value.respond_to?(:html_safe) ? value.html_safe : value
      end
  end
end
