require "logger"
require "mcp"

module Sentrace
  module Mcp
    class StdioRunner
      class << self
        def run(server: Server.build, input: $stdin, output: $stdout, err_output: $stderr, isolate_stdout_logs: true)
          new(
            server: server,
            input: input,
            output: output,
            err_output: err_output,
            isolate_stdout_logs: isolate_stdout_logs
          ).run
        end
      end

      def initialize(server:, input:, output:, err_output:, isolate_stdout_logs:)
        @server = server
        @input = input
        @output = output
        @err_output = err_output
        @isolate_stdout_logs = isolate_stdout_logs
      end

      def run
        previous_rails_logger = defined?(Rails) ? Rails.logger : nil
        previous_ar_logger = defined?(ActiveRecord::Base) ? ActiveRecord::Base.logger : nil
        previous_stdin = $stdin
        previous_stdout = $stdout

        if @isolate_stdout_logs
          stderr_logger = Logger.new(@err_output, level: Logger::WARN)
          Rails.logger = stderr_logger if defined?(Rails) && Rails.respond_to?(:logger=)
          ActiveRecord::Base.logger = stderr_logger if defined?(ActiveRecord::Base)
        end

        $stdin = @input
        $stdout = @output

        transport = ::MCP::Server::Transports::StdioTransport.new(@server)
        @server.transport = transport
        transport.open
      ensure
        $stdin = previous_stdin
        $stdout = previous_stdout
        if @isolate_stdout_logs
          Rails.logger = previous_rails_logger if defined?(Rails) && Rails.respond_to?(:logger=)
          ActiveRecord::Base.logger = previous_ar_logger if defined?(ActiveRecord::Base)
        end
      end
    end
  end
end
