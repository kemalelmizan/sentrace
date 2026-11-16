require "rails_helper"
require "generators/sentrace/install/install_generator"
require "tmpdir"

RSpec.describe Sentrace::Generators::InstallGenerator do
  around do |example|
    Dir.mktmpdir("sentrace-host-app") do |tmpdir|
      @destination = tmpdir
      FileUtils.mkdir_p(File.join(@destination, "config"))
      File.write(
        File.join(@destination, "config/routes.rb"),
        <<~RUBY
          Rails.application.routes.draw do
          end
        RUBY
      )
      example.run
    end
  end

  def run_install_generator
    output = StringIO.new
    Thor::Base.shell.new
    generator = described_class.new([], { quiet: false }, destination_root: @destination)
    allow(generator.shell).to receive(:say) { |msg, *_args| output.puts(msg) }
    allow(generator.shell).to receive(:say_status) { |status, msg, *_args| output.puts("#{status}: #{msg}") }
    generator.invoke_all
    output.string
  end

  it "creates initializer, mounts engine, copies migrations, creates setup task, and prints Sentry.init snippet" do
    output = run_install_generator

    initializer_path = File.join(@destination, "config/initializers/sentrace.rb")
    expect(File.exist?(initializer_path)).to be(true)
    expect(File.read(initializer_path)).to include("Sentrace.configure do |config|")

    routes_content = File.read(File.join(@destination, "config/routes.rb"))
    expect(routes_content.scan("Sentrace::Engine").size).to eq(1)

    copied_migrations = Dir.glob(File.join(@destination, "db/migrate/*.rb"))
    expect(copied_migrations.size).to eq(5)

    setup_task_path = File.join(@destination, "lib/tasks/sentrace_setup.rake")
    expect(File.exist?(setup_task_path)).to be(true)
    expect(File.read(setup_task_path)).to include("task setup: :environment")

    expect(output).to include("Sentry.init do |config|")
    expect(output).to include("@localhost:3000/sentrace/1")
    expect(output).to include("npm install sentrace")
    expect(output).to include("sentrace_meta_tags")
  end

  it "is idempotent when re-run in an already installed host application" do
    run_install_generator
    run_install_generator

    routes_content = File.read(File.join(@destination, "config/routes.rb"))
    expect(routes_content.scan("Sentrace::Engine").size).to eq(1)

    copied_migrations = Dir.glob(File.join(@destination, "db/migrate/*.rb"))
    expect(copied_migrations.size).to eq(5)
  end
end
