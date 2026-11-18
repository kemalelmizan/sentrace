require "erb"

module Sentrace
  module ViewHelpers
    def sentrace_meta_tags(
      dsn: nil,
      project: nil,
      environment: Sentrace.configuration.deployment_environment,
      release: Sentrace.configuration.release,
      request_id: :auto
    )
      return html_safe_string("") unless Sentrace.configuration.enabled

      req = respond_to?(:request) ? request : nil
      public_dsn = FrontendDsnResolver.resolve(request: req, project: project, dsn: dsn)
      return html_safe_string("") if public_dsn.nil? || public_dsn.empty?

      resolved_request_id =
        if request_id == :auto
          req.respond_to?(:request_id) ? req.request_id : nil
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
