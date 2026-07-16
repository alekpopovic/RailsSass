class ApplicationJob < ActiveJob::Base
  around_perform do |job, perform|
    Current.reset
    Current.job_id = job.job_id
    perform.call
  ensure
    Current.reset
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
