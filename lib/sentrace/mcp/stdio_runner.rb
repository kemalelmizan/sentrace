require "json"
require "logger"
require "mcp"

module Sentrace
  module Mcp
    class StdioRunner
      class IsolatedStdioTransport < ::MCP::Server::Transports::StdioTransport
        def initialize(server, output_io:)
          @output_io = output_io
          @output_io.set_encoding("UTF-8") if @output_io.respond_to?(:set_encoding)
          super(server)
        end

        def send_response(message)
          json_message = message.is_a?(String) ? message : JSON.generate(message)
          @output_io.puts(json_message)
          @output_io.flush
        end
      end

      class << self
        def run(server: nil, input: $stdin, output: $stdout, err_output: $stderr, isolate_stdout_logs: true, read_only: env_read_only?)
          resolved_server = server || Server.build(dispatcher: Dispatcher.new(read_only: read_only))
          new(
            server: resolved_server,
            input: input,
            output: output,
            err_output: err_output,
            isolate_stdout_logs: isolate_stdout_logs
          ).run
        end

        private
          def env_read_only?
            ENV["SENTRACE_MCP_READ_ONLY"].to_s.casecmp("true").zero?
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
        duplicated_output = nil
        reopened_stdout_fd = false

        if @isolate_stdout_logs
          stderr_logger = Logger.new(@err_output, level: Logger::WARN)
          Rails.logger = stderr_logger if defined?(Rails) && Rails.respond_to?(:logger=)
          ActiveRecord::Base.logger = stderr_logger if defined?(ActiveRecord::Base)

          if @output.equal?(previous_stdout) && @output.respond_to?(:dup)
            duplicated_output = @output.dup
            duplicated_output.sync = true if duplicated_output.respond_to?(:sync=)
            mcp_output = duplicated_output

            if @output.equal?(STDOUT) && @output.is_a?(IO) && @err_output.is_a?(IO)
              STDOUT.reopen(@err_output)
              STDOUT.sync = true
              reopened_stdout_fd = true
            end
          else
            mcp_output = @output
            mcp_output.sync = true if mcp_output.respond_to?(:sync=)
          end

          $stdin = @input
          $stdout = @err_output
        else
          mcp_output = @output
          $stdin = @input
          $stdout = @output
        end

        transport = IsolatedStdioTransport.new(@server, output_io: mcp_output)
        @server.transport = transport
        transport.open
      ensure
        if reopened_stdout_fd && duplicated_output && !duplicated_output.closed?
          STDOUT.reopen(duplicated_output)
        end
        duplicated_output.close if duplicated_output.respond_to?(:close) && !duplicated_output.closed?
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
