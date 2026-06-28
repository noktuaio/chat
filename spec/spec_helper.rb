require 'webmock/rspec'

# Block real outbound HTTP in specs (allow localhost for system/integration).
# This was stripped from the fork's spec_helper, letting specs hit the network.
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Defined here (not via config.include) so it is also callable at example-group
  # level, e.g. `with_modified_env(...) do ... end` wrapping describe/context —
  # some specs rely on that. Wraps ClimateControl (see CLAUDE.md).
  def with_modified_env(options, &)
    ClimateControl.modify(options, &)
  end
end
