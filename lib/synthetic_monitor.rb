require 'rspec'
require 'rspec/core'
require 'rspec/core/formatters/json_formatter'
require 'rest-client'

$stdout.sync = true #so we can see stdout when starting with foreman, see https://github.com/ddollar/foreman/wiki/Missing-Output

class SyntheticMonitor

  def initialize (
      frequency_in_minutes: frequency_in_minutes = 5,
      success_notifications_url: success_notifications_url = nil
    )
    @frequency_in_minutes = frequency_in_minutes
    @success_notifications_url = success_notifications_url

    config = RSpec.configuration
    @formatter = RSpec::Core::Formatters::JsonFormatter.new(config.output_stream)

    # create reporter with json formatter
    reporter =  RSpec::Core::Reporter.new(config)
    config.instance_variable_set(:@reporter, reporter)

    # internal hack
    # api may not be stable, make sure lock down Rspec version
    loader = config.send(:formatter_loader)
    notifications = loader.send(:notifications_for, RSpec::Core::Formatters::JsonFormatter)

    reporter.register_listener(@formatter, *notifications)
  end

  def to_slack_fields failed_tests
    failed_tests.map { |f| { "title" => "#{f[:full_description]}", "value" => "\n#{f[:exception][:message]}\n# #{f[:file_path]}:#{f[:line_number]}\n===================================================" } }
  end

  def select_failed_tests all_tests
    all_tests.select { | example | example[:status] == "failed" }
  end

  def notify_all_tests_passed
    RestClient.post @success_notifications_url, { 'data' => "all monitoring tests passed"}.to_json, :content_type => :json, :accept => :json
  end

  def handle_passing_tests
    puts "\nAll tests passed\n"
    notify_all_tests_passed if @success_notifications_url
  end

  def notify_on_slack result, slack_webhook_url
    puts "\ntests failed; notifying on slack\n"
    failure_count = result[:summary][:failure_count]
    title = (failure_count == 1) ? "ALERT: 1 test failed" : "ALERT: #{failure_count} tests failed"
    attachments = [
      {
        "fallback" => title,
        "color" => "danger",
        "title" => title,
        "fields" => to_slack_fields(select_failed_tests result[:examples])
      }
    ]
    RestClient.post slack_webhook_url, { 'attachments' => attachments}.to_json, :content_type => :json, :accept => :json
  end

  def all_tests_passed? result
    result[:summary][:failure_count] == 0
  end

  def run_spec_slack_pairs spec_slack_pairs
    spec_slack_pairs.each_pair {|spec, slack_webhook_url| run spec, slack_webhook_url}
  end

  def run spec, slack_webhook_url
    puts "monitoring specs: #{spec}"
    RSpec::Core::Runner.run([spec])
    f = @formatter
    result = @formatter.output_hash
    all_tests_passed?(result) ? (handle_passing_tests) : (notify_on_slack result, slack_webhook_url)
    RSpec.clear_examples
  end

  def monitor specs="spec", *additional_specs, slack_webhook_url
    specs_to_run = additional_specs << specs
    loop do
      run specs_to_run, slack_webhook_url
      sleep 60*@frequency_in_minutes.to_i
    end
  end

  def monitor_on_varying_slack_channels spec_slack_pairs
    loop do
      run_spec_slack_pairs spec_slack_pairs
      sleep 60*@frequency_in_minutes.to_i
    end
  end

end
