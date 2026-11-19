module Sentrace
  class ApplicationController < ActionController::API
    before_action :apply_security_headers
    after_action :apply_security_headers

    private
      def apply_security_headers
        RequestSecurity.apply_security_headers!(response)
      end
  end
end
