module Sentrace
  class ApplicationController < ActionController::API
    before_action :set_no_store_cache_control
    after_action :set_no_store_cache_control

    private
      def set_no_store_cache_control
        response.set_header("Cache-Control", "no-store")
      end
  end
end
