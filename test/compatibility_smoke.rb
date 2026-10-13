# Run from a migrated Redmine development/test installation:
# bundle exec rails runner plugins/redmine_work_time/test/compatibility_smoke.rb
require 'securerandom'
require 'nokogiri'
require 'csv'
STDOUT.sync = true

raise 'Use the development or test database' unless Rails.env.development? || Rails.env.test?
ActionMailer::Base.perform_deliveries = false
ActionController::Base.allow_forgery_protection = true
checks = 0
check = lambda do |condition, description|
  raise "FAIL: #{description}" unless condition
  checks += 1
  puts "PASS: #{description}"
end

begin
  ActiveRecord::Base.transaction do
    suffix = SecureRandom.hex(5)
    password = SecureRandom.base64(24)
    user = User.new(login: "worktime-smoke-#{suffix}", firstname: 'WorkTime', lastname: 'Test',
                    mail: "#{suffix}@example.invalid", status: User::STATUS_ACTIVE, language: 'en')
    user.password = password
    user.password_confirmation = password
    user.save!
    role = Role.create!(name: "WorkTime smoke #{suffix}", permissions: [
      :view_issues, :view_time_entries, :log_time, :edit_own_time_entries, :edit_project,
      :view_work_time_tab, :view_work_time_other_member, :edit_work_time_total
    ])
    tracker = Tracker.first!
    project = Project.create!(name: "WorkTime smoke #{suffix}", identifier: "worktime-smoke-#{suffix}",
                               is_public: false)
    project.enabled_module_names = ['issue_tracking', 'time_tracking', 'work_time']
    project.trackers = [tracker]
    Member.create!(project: project, user: user, roles: [role])
    User.current = user
    issue = Issue.create!(project: project, tracker: tracker, author: user,
                          subject: "WorkTime decimal regression #{suffix}", assigned_to: user)
    date = Date.today
    TimeEntry.create!(project: project, issue: issue, user: user, hours: '4.75', spent_on: date,
                      activity: TimeEntryActivity.active.first!)

    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.host! 'localhost'
    session.get '/login'
    token = Nokogiri::HTML(session.response.body).at_css('input[name="authenticity_token"]')&.[]('value')
    session.post '/login', params: {username: user.login, password: password, authenticity_token: token}
    check.call(session.response.redirect?, 'non-admin login')
    period = {id: project.id, user: user.id, year: date.year, month: date.month, day: date.day, prj: project.id}
    request = lambda do |action, params = {}, status = 200, method = :get|
      if method == :post
        session.get '/work_time/index', params: {user: user.id}
        csrf = Nokogiri::HTML(session.response.body).at_css('meta[name="csrf-token"]')&.[]('content')
        params = params.merge(authenticity_token: csrf)
      end
      session.public_send(method, "/work_time/#{action}", params: period.merge(params))
      check.call(session.response.status == status,
                 "GET #{action}: #{status} (got #{session.response.status})")
      session.response
    end

    # The first relay lookup must tolerate an issue without a stored mapping.
    check.call(!WtTicketRelay.exists?(issue_id: issue.id), 'new issue has no ticket relay')
    request.call('ajax_relay', {issue_id: issue.id})
    request.call('ajax_relay', {}, 200)
    check.call(session.response.body == 'ERROR: no issue_id', 'missing relay issue returns plain text')
    request.call('ajax_add_tickets_insert', {add_issue: -1, count: 0}, 200, :post)
    request.call('show')
    check.call(session.response.body.include?(issue.subject), 'daily/monthly view includes the test issue')
    check.call(session.response.body.include?('4.75'), 'daily/monthly view displays decimal hours')

    request.call('member_monthly_data')
    check.call(session.response.body.include?(',4.75') && !session.response.body.include?('19/4'),
               'member CSV contains decimal hours rather than fractions')
    request.call('member_monthly_data_table')
    check.call(CSV.parse(session.response.body).flatten.include?('4.75'), 'monthly matrix CSV contains decimal hours')
    request.call('total')
    request.call('relay_total')
    %w(total_data total_data_with_act relay_total_data relay_total_data_with_act).each do |action|
      request.call(action)
      check.call(session.response.body.include?('4.75') && !session.response.body.include?('19/4'),
                 "#{action} CSV contains decimal hours")
    end

    %w(show total total_data total_data_with_act edit_relay relay_total_data
       relay_total_data_with_act member_monthly_data member_monthly_data_table ajax_relay
       register_project_settings).each do |action|
      request.call(action, {id: -1, issue_id: issue.id}, 404)
    end

    session.get "/projects/#{project.identifier}/settings", params: {tab: 'work_time'}
    check.call(session.response.status == 200,
               "project settings render with the installed helper wrappers (got #{session.response.status})")
    settings_page = Nokogiri::HTML(session.response.body)
    check.call(settings_page.css('#tab-work_time').length == 1, 'project settings contain exactly one WorkTime tab')
    check.call(settings_page.at_css('input[name="account_start_day"]')&.[]('value') == '1',
               'project accounting start day defaults to 1')
    token = settings_page.at_css('meta[name="csrf-token"]')&.[]('content')
    session.post '/work_time/register_project_settings', params: {
      id: project.id, account_start_day: '15', authenticity_token: token
    }
    check.call(session.response.redirect? &&
               Setting.plugin_redmine_work_time.dig('account_start_days', project.id.to_s) == '15',
               'project accounting start day persists')

    %w(calc_total hour_update update_relay ajax_memo_edit).each do |action|
      begin
        Rails.application.routes.recognize_path("/work_time/#{action}", method: :get)
        raise "Unexpected public route for #{action}"
      rescue ActionController::RoutingError
        check.call(true, "#{action} has no public action route")
      end
    end
    raise ActiveRecord::Rollback
  end
ensure
  User.current = nil
end

puts "PASS: #{checks} WorkTime compatibility checks; temporary records rolled back"
