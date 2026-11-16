module Sentrace
  module Mcp
    class Dispatcher
      DEFAULT_REMOTE_CLIENT = Object.new.freeze
      private_constant :DEFAULT_REMOTE_CLIENT

      def initialize(config: Sentrace.configuration, remote_client: DEFAULT_REMOTE_CLIENT, router: nil)
        @config = config
        resolved_client = remote_client.equal?(DEFAULT_REMOTE_CLIENT) ? RemoteHttpClient.new : remote_client
        @remote_client = resolved_client
        @router = router || EnvironmentRouter.new(config: @config, remote_client: @remote_client)
      end

      def list_environments
        @router.list_environments
      end

      def dispatch(operation, environment: nil, **kwargs)
        @router.route(operation, environment: environment, **kwargs)
      end
    end
  end
end
