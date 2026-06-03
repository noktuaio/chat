namespace :onboarding do # rubocop:disable Metrics/BlockLength
  # Resets onboarding for an account so the onboarding flow runs again.
  # Interactively prompts for an account ID, then resets the onboarding step
  # and deletes the account's inboxes and help center (portals, categories, articles).
  #
  # How to run:
  #   bundle exec rake onboarding:reset
  #
  # You will be prompted for the account ID and a confirmation (y/N).
  desc 'Reset onboarding for an account (interactive). Resets the onboarding step and deletes inboxes and help center articles.'
  task reset: :environment do # rubocop:disable Metrics/BlockLength
    print 'Enter the account ID to reset onboarding for: '
    account_id = $stdin.gets&.strip

    abort 'Error: Please provide an account ID' if account_id.blank?

    account = Account.find_by(id: account_id)
    abort "Error: Account with ID '#{account_id}' not found" unless account

    puts "\nAccount: #{account.name} (ID: #{account.id})"
    puts "Current onboarding step: #{account.custom_attributes['onboarding_step'] || '(none)'}"

    if account.inboxes.any?
      puts "\nInboxes (#{account.inboxes.count}):"
      account.inboxes.each { |inbox| puts "  - ##{inbox.id} #{inbox.name} [#{inbox.channel_type}]" }
    end

    if account.portals.any?
      puts "\nPortals (#{account.portals.count}):"
      account.portals.each { |portal| puts "  - ##{portal.id} #{portal.name}" }
    end

    if account.articles.any?
      puts "\nHelp center articles (#{account.articles.count}):"
      account.articles.each { |article| puts "  - ##{article.id} #{article.title}" }
    end

    puts "\nTo be deleted: #{account.inboxes.count} inbox(es), #{account.portals.count} portal(s), " \
         "#{account.categories.count} category(ies), #{account.articles.count} article(s)."

    print "\nReset onboarding for '#{account.name}' (ID: #{account.id}) and delete the above? (y/N): "
    abort 'Aborted' unless $stdin.gets&.strip&.casecmp?('y')

    account.custom_attributes['onboarding_step'] = 'account_details'
    # Seed the socials the website branding service would have detected so the
    # onboarding inbox setup UI has channels to render. Mirrors the shape of
    # WebsiteBrandingService#build_socials (keys map to SocialLinkParser).
    account.custom_attributes['brand_info'] ||= {}
    account.custom_attributes['brand_info']['socials'] = [
      { 'type' => 'whatsapp', 'url' => 'https://wa.me/14155552671' },
      { 'type' => 'facebook', 'url' => 'https://facebook.com/chatwoot' },
      { 'type' => 'telegram', 'url' => 'https://t.me/chatwoot' },
      { 'type' => 'instagram', 'url' => 'https://instagram.com/chatwoot' },
      { 'type' => 'line', 'url' => 'https://line.me/chatwoot' },
      { 'type' => 'tiktok', 'url' => 'https://tiktok.com/@chatwoot' }
    ]
    account.save!

    account.inboxes.destroy_all
    account.articles.destroy_all
    account.categories.destroy_all
    account.portals.destroy_all

    puts "\nOnboarding has been reset for account '#{account.name}' (ID: #{account.id}). Inboxes and help center articles deleted."
  end
end
