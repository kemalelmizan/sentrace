module Sentrace
  module Internal
    class StatsController < BaseController
      def show
        days = params[:days] ? params[:days].to_i : 30
        render json: StorageStats.collect(days: days)
      end
    end
  end
end
