namespace :sentrace do
  desc "Display PostgreSQL storage and retention statistics for Sentrace"
  task stats: :environment do
    Sentrace::StorageStats.print_report
  end

  namespace :retention do
    desc "Delete expired Sentrace events and aged zero-event orphan issues in bounded batches"
    task cleanup: :environment do
      result = Sentrace::Retention::Cleaner.run!
      puts "Sentrace retention cleanup complete:"
      puts "  Deleted expired events: #{result.deleted_events_count} (#{result.event_batches} batches, cutoff #{result.event_cutoff.iso8601})"
      puts "  Deleted orphan issues:  #{result.deleted_orphan_issues_count} (#{result.issue_batches} batches, cutoff #{result.orphan_issue_cutoff.iso8601})"
    end
  end
end
