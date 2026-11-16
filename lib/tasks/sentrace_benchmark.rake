namespace :sentrace do
  namespace :benchmark do
    desc "Run repeatable PostgreSQL storage, throughput, and latency benchmark (EVENTS=500)"
    task storage: :environment do
      event_count = ENV.fetch("EVENTS", Sentrace::Benchmark::StorageRunner::DEFAULT_EVENT_COUNT).to_i
      Sentrace::Benchmark::StorageRunner.print_report(event_count: event_count)
    end
  end
end
