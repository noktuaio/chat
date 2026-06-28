require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'

require File.expand_path('../config/environment', __dir__)
abort('The Rails environment is running in production mode!') if Rails.env.production?

require 'rspec/rails'
require 'pundit/rspec'
require 'sidekiq/testing'

# Load Rake tasks — some specs exercise rake tasks.
require 'rake'
Rails.application.load_tasks

# test-prof helpers (before_all / let_it_be) used across model and builder specs.
require 'test_prof/recipes/rspec/before_all'
require 'test_prof/recipes/rspec/let_it_be'

require 'active_job/test_helper'

Dir[Rails.root.join('spec/support/**/*.rb')].sort.each { |file| require file }

# Checks for pending migrations and applies them before tests are run.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  puts e.to_s.strip
  exit 1
end

RSpec.configure do |config|
  config.fixture_path = Rails.root.join('spec/fixtures').to_s
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include SlackStubs
  config.include FileUploadHelpers
  config.include CsvSpecHelpers
  config.include InstagramSpecHelpers
  config.include ConversationsUnreadCountsHelpers
  config.include Devise::Test::IntegrationHelpers, type: :request
  config.include Devise::Test::ControllerHelpers, type: :controller
  config.include ActiveSupport::Testing::TimeHelpers
  config.include ActionCable::TestHelper
  config.include ActiveJob::TestHelper

  # OpenAPI response validation via Skooma (request specs).
  config.include Skooma::RSpec[Rails.root.join('swagger/swagger.json')], type: :request

  config.before do
    ActiveJob::Base.queue_adapter = :test
    ActiveStorage::Current.url_options = { host: 'www.example.com' }
  end
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

# Required so factories can use fixture_file_upload.
FactoryBot::SyntaxRunner.class_eval do
  include ActionDispatch::TestProcess
  include ActiveSupport::Testing::FileFixtures
end
