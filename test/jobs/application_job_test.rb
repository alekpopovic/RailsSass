require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  class ContextCaptureJob < ApplicationJob
    class_attribute :captured_context, instance_accessor: false

    def perform
      self.class.captured_context = {
        session: Current.session,
        organization: Current.organization,
        membership: Current.membership,
        request_id: Current.request_id,
        job_id: Current.job_id
      }
    end
  end

  setup do
    ContextCaptureJob.captured_context = nil
    Current.reset
  end

  teardown do
    ContextCaptureJob.captured_context = nil
    Current.reset
  end

  test "jobs receive only their own correlation context and clear it afterwards" do
    Current.session = Object.new
    Current.organization = Object.new
    Current.membership = Object.new
    Current.request_id = "request-that-must-not-leak"

    job = ContextCaptureJob.new
    job.perform_now
    captured = ContextCaptureJob.captured_context

    assert_nil captured.fetch(:session)
    assert_nil captured.fetch(:organization)
    assert_nil captured.fetch(:membership)
    assert_nil captured.fetch(:request_id)
    assert_equal job.job_id, captured.fetch(:job_id)
    assert Current.attributes.values.all?(&:nil?)
  end
end
