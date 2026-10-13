# Authorization and workflow regressions for WorkTime.
# bundle exec rails runner plugins/redmine_work_time/test/workflow_audit.rb
# All test records and settings changes are rolled back; no mail is delivered.
require 'securerandom'
require 'json'
require 'csv'
require 'nokogiri'

raise 'Use a migrated development/test database' unless Rails.env.development? || Rails.env.test?
ActionMailer::Base.perform_deliveries = false
ActionController::Base.allow_forgery_protection = true
STDOUT.sync = true
results = []
probe = lambda do |name, &block|
  begin
    passed, detail = block.call
    results << {name: name, passed: !!passed, detail: detail}
  rescue StandardError => error
    results << {name: name, passed: false, detail: "#{error.class}: #{error.message.lines.first.strip}"}
  end
  puts "#{results.last[:passed] ? 'PASS' : 'FAIL'}: #{name}: #{results.last[:detail]}"
end

begin
  ActiveRecord::Base.transaction do
    suffix = SecureRandom.hex(5)
    password = SecureRandom.base64(24)
    permissions = {
      employee: [:view_issues, :view_time_entries, :log_time, :edit_own_time_entries, :view_work_time_tab],
      viewer: [:view_issues, :view_time_entries, :view_work_time_tab, :view_work_time_other_member],
      manager: [:view_issues, :edit_issues, :view_time_entries, :log_time, :log_time_for_other_users,
                :edit_time_entries, :edit_own_time_entries, :view_work_time_tab,
                :view_work_time_other_member, :edit_work_time_other_member, :edit_work_time_total, :edit_project],
      outsider: [:view_issues, :view_time_entries, :log_time, :edit_own_time_entries, :view_work_time_tab]
    }
    users, roles = {}, {}
    permissions.each do |key, perms|
      roles[key] = Role.create!(name: "WorkTime audit #{key} #{suffix}", permissions: perms, issues_visibility: 'default')
      user = User.new(login: "wtaudit-#{key}-#{suffix}", firstname: 'WorkTime audit', lastname: key.to_s,
                      mail: "wtaudit-#{key}-#{suffix}@example.invalid", status: User::STATUS_ACTIVE, language: 'en')
      user.password = password
      user.password_confirmation = password
      user.save!
      users[key] = user
    end
    tracker = Tracker.first!
    projects = [:main, :foreign].to_h do |key|
      project = Project.create!(name: "WorkTime audit #{key} #{suffix}",
                                 identifier: "wtaudit-#{key}-#{suffix}", is_public: false)
      project.enabled_module_names = ['issue_tracking', 'time_tracking', 'work_time']
      project.trackers = [tracker]
      [key, project]
    end
    [:employee, :viewer, :manager].each do |key|
      Member.create!(project: projects[:main], user: users[key], roles: [roles[key]])
    end
    Member.create!(project: projects[:foreign], user: users[:outsider], roles: [roles[:outsider]])
    issues = {}
    {entry: [:main, :employee], target: [:main, :manager], foreign: [:foreign, :outsider]}.each do |key, (project_key, user_key)|
      User.current = users[user_key]
      issues[key] = Issue.create!(project: projects[project_key], tracker: tracker, author: users[user_key],
                                  assigned_to: users[user_key], subject: "WorkTime audit #{key} #{suffix}")
    end
    date = Date.new(2026, 10, 13)
    activity = TimeEntryActivity.active.first!
    own_entry = TimeEntry.create!(project: projects[:main], issue: issues[:entry], user: users[:employee],
                                  hours: 4.75, spent_on: date, activity: activity)
    foreign_entry = TimeEntry.create!(project: projects[:foreign], issue: issues[:foreign], user: users[:outsider],
                                      hours: 3, spent_on: date, activity: activity)
    sessions = {}
    users.each do |key, user|
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.host! 'localhost'
      session.get '/login'
      token = Nokogiri::HTML(session.response.body).at_css('input[name="authenticity_token"]')&.[]('value')
      session.post '/login', params: {username: user.login, password: password, authenticity_token: token}
      raise "Login failed for #{key}" unless session.response.redirect?
      sessions[key] = session
    end
    period = {id: projects[:main].id, user: users[:employee].id, year: 2026, month: 10, day: 13}
    post = lambda do |who, action, params|
      session = sessions.fetch(who)
      session.get '/work_time/index'
      3.times do
        break unless session.response.redirect?
        session.follow_redirect!
      end
      token = Nokogiri::HTML(session.response.body).at_css('meta[name="csrf-token"]')&.[]('content')
      raise "Missing CSRF token for #{who}" if token.blank?
      session.post "/work_time/#{action}", params: period.merge(params).merge(authenticity_token: token)
      session.response
    end

    probe.call('ordinary own time entry is editable') do
      response = post.call(:employee, 'index', {time_entry: {own_entry.id.to_s => {hours: '2:30'}}})
      [response.status == 200 && own_entry.reload.hours.to_f == 2.5, "HTTP #{response.status}; hours=#{own_entry.hours.to_f}"]
    end
    probe.call('read-only role cannot change accounting start day') do
      before = Setting.plugin_redmine_work_time.deep_dup
      response = post.call(:viewer, 'register_project_settings', {account_start_day: '20'})
      [Setting.plugin_redmine_work_time == before, "HTTP #{response.status}; setting changed=#{Setting.plugin_redmine_work_time != before}"]
    end
    # Restore the expected period so subsequent checks are independent.
    settings = Setting.plugin_redmine_work_time.deep_dup
    settings['account_start_days'] ||= {}
    settings['account_start_days'][projects[:main].id.to_s] = '1'
    Setting.plugin_redmine_work_time = settings
    probe.call('missing time entry is handled without HTTP 500') do
      response = post.call(:employee, 'index', {time_entry: {'-1' => {hours: '1.0'}}})
      [response.status < 500, "HTTP #{response.status}"]
    end
    probe.call('foreign project time entry cannot be altered') do
      response = post.call(:employee, 'index', {time_entry: {foreign_entry.id.to_s => {hours: '9.0'}}})
      [foreign_entry.reload.hours.to_f == 3, "HTTP #{response.status}; hours=#{foreign_entry.hours.to_f}"]
    end
    probe.call('foreign project time entry cannot be deleted') do
      response = post.call(:employee, 'index', {time_entry: {foreign_entry.id.to_s => {hours: ''}}})
      [TimeEntry.exists?(foreign_entry.id), "HTTP #{response.status}; exists=#{TimeEntry.exists?(foreign_entry.id)}"]
    end
    probe.call('another user daily note cannot be overwritten') do
      response = post.call(:employee, 'index', {user: users[:manager].id, memo: "Unauthorized note #{suffix}"})
      changed = WtDailyMemo.exists?(user_id: users[:manager].id, day: date, description: "Unauthorized note #{suffix}")
      [!changed, "HTTP #{response.status}; unauthorized note saved=#{changed}"]
    end
    holiday = Date.new(2098, 1, 3)
    holiday += 1 while WtHolidays.exists?(holiday: holiday)
    probe.call('non-admin cannot create global holidays') do
      response = post.call(:employee, 'index', {set_holiday: holiday.to_s})
      changed = WtHolidays.exists?(holiday: holiday, deleted_on: nil)
      [!changed, "HTTP #{response.status}; unauthorized holiday saved=#{changed}"]
    end
    probe.call('accounting start day 31 works in a short month') do
      settings = Setting.plugin_redmine_work_time.deep_dup
      settings['account_start_days'][projects[:main].id.to_s] = '31'
      Setting.plugin_redmine_work_time = settings
      sessions[:manager].get '/work_time/show', params: period.merge(month: 3, day: 15)
      [sessions[:manager].response.status == 200, "HTTP #{sessions[:manager].response.status}"]
    end
    settings = Setting.plugin_redmine_work_time.deep_dup
    settings['account_start_days'][projects[:main].id.to_s] = '1'
    Setting.plugin_redmine_work_time = settings
    probe.call('missing issue in progress popup is handled without HTTP 500') do
      sessions[:employee].get '/work_time/ajax_done_ratio_input', params: period.merge(issue_id: -1)
      [sessions[:employee].response.status < 500, "HTTP #{sessions[:employee].response.status}"]
    end
    relay = WtTicketRelay.find_or_create_by!(issue_id: issues[:entry].id)
    relay.update!(parent: issues[:foreign].id)
    probe.call('relay lookup does not reveal an inaccessible issue title') do
      sessions[:employee].get '/work_time/ajax_relay', params: period.merge(issue_id: issues[:entry].id)
      response = sessions[:employee].response
      leaked = response.body.include?(issues[:foreign].subject)
      [!leaked, "HTTP #{response.status}; hidden title exposed=#{leaked}"]
    end
    probe.call('API handles an inaccessible relay target without HTTP 500') do
      Setting.rest_api_enabled = '1'
      sessions[:manager].get '/work_time/relay_total.json', params: period.merge(prj: projects[:main].id),
        headers: {'X-Redmine-API-Key' => users[:manager].api_key}
      [sessions[:manager].response.status == 200, "HTTP #{sessions[:manager].response.status}"]
    end
    probe.call('CSV preserves quotes and commas in issue subjects') do
      Issue.where(id: issues[:entry].id).update_all(subject: 'QA "quoted", title')
      ActiveRecord::Base.connection.clear_query_cache
      sessions[:employee].get '/work_time/member_monthly_data', params: period
      response = sessions[:employee].response
      raise "Unexpected HTTP #{response.status}" unless response.status == 200
      rows = CSV.parse(response.body)
      [rows.any? { |row| row.any? { |value| value.to_s.include?('QA "quoted", title') } },
       "HTTP #{response.status}; type=#{response.media_type}"]
    end
    probe.call('relay labels escape issue title markup') do
      Issue.where(id: issues[:target].id).update_all(subject: '<strong data-wtqa="markup">QA escaped title</strong>')
      relay.update!(parent: issues[:target].id)
      ActiveRecord::Base.connection.clear_query_cache
      sessions[:employee].get '/work_time/ajax_relay', params: period.merge(issue_id: issues[:entry].id)
      response = sessions[:employee].response
      interpreted = Nokogiri::HTML.fragment(response.body).at_css('strong[data-wtqa="markup"]').present?
      [!interpreted && response.body.include?('QA escaped title'),
       "HTTP #{response.status}; title interpreted as HTML=#{interpreted}"]
    end

    probe.call('GET cannot modify a time entry') do
      before = own_entry.reload.hours
      sessions[:employee].get '/work_time/index', params: period.merge(time_entry: {own_entry.id.to_s => {hours: '8'}})
      [sessions[:employee].response.status == 405 && own_entry.reload.hours == before,
       "HTTP #{sessions[:employee].response.status}"]
    end
    probe.call('POST without CSRF token cannot modify a time entry') do
      before = own_entry.reload.hours
      sessions[:employee].post '/work_time/index', params: period.merge(time_entry: {own_entry.id.to_s => {hours: '8'}})
      [sessions[:employee].response.status == 422 && own_entry.reload.hours == before,
       "HTTP #{sessions[:employee].response.status}"]
    end
    # Rails intentionally resets the session after a CSRF failure. Restore the
    # employee login before testing subsequent, independently authorized writes.
    sessions[:employee].get '/login'
    csrf = Nokogiri::HTML(sessions[:employee].response.body).at_css('input[name="authenticity_token"]')&.[]('value')
    sessions[:employee].post '/login', params: {
      username: users[:employee].login, password: password, authenticity_token: csrf
    }
    raise 'Employee re-login failed' unless sessions[:employee].response.redirect?
    probe.call('form fields cannot reassign a time entry or change its date') do
      response = post.call(:employee, 'index', {
        time_entry: {own_entry.id.to_s => {hours: '3', user_id: users[:outsider].id, project_id: projects[:foreign].id,
                                         issue_id: issues[:foreign].id, spent_on: '2026-01-01'}},
        "time_entry_#{own_entry.id}" => {user_id: users[:outsider].id, project_id: projects[:foreign].id}
      })
      own_entry.reload
      [response.status == 200 && own_entry.hours.to_f == 3 && own_entry.user_id == users[:employee].id &&
       own_entry.project_id == projects[:main].id && own_entry.issue_id == issues[:entry].id && own_entry.spent_on == date,
       "HTTP #{response.status}; ownership/date preserved"]
    end
    probe.call('new time entry accepts minutes and ignores forged ownership') do
      response = post.call(:employee, 'index', {new_time_entry: {issues[:entry].id.to_s => {'0' => {
        hours: '90m', activity_id: activity.id, comments: "New minutes #{suffix}", user_id: users[:outsider].id,
        project_id: projects[:foreign].id, spent_on: '2026-01-01'
      }}}})
      entry = TimeEntry.find_by(comments: "New minutes #{suffix}")
      [response.status == 200 && entry && entry.hours.to_f == 1.5 && entry.user_id == users[:employee].id &&
       entry.project_id == projects[:main].id && entry.spent_on == date, "HTTP #{response.status}"]
    end
    probe.call('authorized manager can edit another member and preserve the audit note') do
      response = post.call(:manager, 'show', {time_entry: {own_entry.id.to_s => {hours: '3.25'}}})
      memo = WtDailyMemo.find_by(user_id: users[:employee].id, day: date)
      [response.status == 200 && own_entry.reload.hours.to_f == 3.25 && memo&.description&.include?('update time entry'),
       "HTTP #{response.status}; audit note retained"]
    end
    probe.call('authorized manager can log time for another member') do
      response = post.call(:manager, 'show', {new_time_entry: {issues[:entry].id.to_s => {'0' => {
        hours: '0.5', activity_id: activity.id, comments: "Manager entry #{suffix}"
      }}}})
      entry = TimeEntry.find_by(comments: "Manager entry #{suffix}")
      [response.status == 200 && entry && entry.user_id == users[:employee].id && entry.author_id == users[:manager].id,
       "HTTP #{response.status}"]
    end
    probe.call('read-only member cannot edit another member') do
      before = own_entry.reload.hours
      response = post.call(:viewer, 'show', {time_entry: {own_entry.id.to_s => {hours: '8'}}})
      [response.status == 404 && own_entry.reload.hours == before, "HTTP #{response.status}"]
    end
    probe.call('work time permission does not override standard edit permission') do
      permissions_before = roles[:employee].permissions
      roles[:employee].update!(permissions: permissions_before - [:edit_own_time_entries])
      before = own_entry.reload.hours
      response = post.call(:employee, 'index', {time_entry: {own_entry.id.to_s => {hours: '8'}}})
      roles[:employee].update!(permissions: permissions_before)
      [response.status == 404 && own_entry.reload.hours == before, "HTTP #{response.status}"]
    end
    probe.call('member selection cannot reach a non-member of the selected project') do
      sessions[:manager].get '/work_time/show', params: period.merge(user: users[:outsider].id)
      [sessions[:manager].response.status == 404, "HTTP #{sessions[:manager].response.status}"]
    end
    probe.call('forged filter cannot expose a private project') do
      sessions[:employee].get '/work_time/show', params: period.merge(prj: projects[:foreign].id)
      [sessions[:employee].response.status == 404, "HTTP #{sessions[:employee].response.status}"]
    end
    probe.call('project reports require view-other-member permission') do
      sessions[:employee].get '/work_time/total', params: period
      [sessions[:employee].response.status == 403, "HTTP #{sessions[:employee].response.status}"]
    end
    hidden = Issue.create!(project: projects[:main], tracker: tracker, author: users[:manager],
                            assigned_to: users[:manager], is_private: true, subject: "Private #{suffix}")
    probe.call('progress popup cannot read a private issue') do
      sessions[:employee].get '/work_time/ajax_done_ratio_input', params: period.merge(issue_id: hidden.id)
      [sessions[:employee].response.status == 404, "HTTP #{sessions[:employee].response.status}"]
    end
    probe.call('AJAX ticket choices exclude private issues') do
      sessions[:employee].get '/work_time/ajax_add_tickets_input_select', params: period.merge(prj: projects[:main].id)
      [sessions[:employee].response.status == 200 && !sessions[:employee].response.body.include?(hidden.subject),
       "HTTP #{sessions[:employee].response.status}"]
    end
    probe.call('GET progress update is rejected') do
      before = issues[:entry].reload.done_ratio
      sessions[:manager].get '/work_time/ajax_done_ratio_update', params: period.merge(issue_id: issues[:entry].id, done_ratio: '75')
      [sessions[:manager].response.status == 405 && issues[:entry].reload.done_ratio == before,
       "HTTP #{sessions[:manager].response.status}"]
    end
    probe.call('authorized POST progress update persists') do
      response = post.call(:manager, 'ajax_done_ratio_update', {issue_id: issues[:entry].id, done_ratio: '50'})
      [response.status == 200 && issues[:entry].reload.done_ratio == 50, "HTTP #{response.status}"]
    end
    probe.call('invalid progress is rejected') do
      response = post.call(:manager, 'ajax_done_ratio_update', {issue_id: issues[:entry].id, done_ratio: '150'})
      [response.status == 400 && issues[:entry].reload.done_ratio == 50, "HTTP #{response.status}"]
    end
    probe.call('GET ticket insert cannot persist ordering') do
      before = UserIssueMonth.count
      sessions[:employee].get '/work_time/ajax_add_tickets_insert', params: period.merge(add_issue: issues[:target].id, count: '0')
      [sessions[:employee].response.status == 405 && UserIssueMonth.count == before, "HTTP #{sessions[:employee].response.status}"]
    end
    probe.call('GET relay changes are rejected') do
      before = relay.reload.parent
      sessions[:manager].get '/work_time/ajax_relay', params: period.merge(issue_id: issues[:entry].id, parent_id: 0)
      [sessions[:manager].response.status == 405 && relay.reload.parent == before, "HTTP #{sessions[:manager].response.status}"]
    end
    probe.call('member without management permission cannot change a relay') do
      before = relay.reload.parent
      response = post.call(:employee, 'ajax_relay', {issue_id: issues[:entry].id, parent_id: 0})
      [response.status == 403 && relay.reload.parent == before, "HTTP #{response.status}"]
    end
    probe.call('authorized relay changes persist') do
      response = post.call(:manager, 'ajax_relay', {issue_id: issues[:entry].id, parent_id: issues[:target].id})
      [response.status == 200 && relay.reload.parent == issues[:target].id, "HTTP #{response.status}"]
    end
    probe.call('new relay cycles are rejected') do
      target_relay = WtTicketRelay.find_or_create_by!(issue_id: issues[:target].id)
      target_relay.update!(parent: 0)
      response = post.call(:manager, 'ajax_relay', {issue_id: issues[:target].id, parent_id: issues[:entry].id})
      [response.status == 200 && target_relay.reload.parent == 0 && response.body.include?(I18n.t(:wt_loop_relay, locale: :en)),
       "HTTP #{response.status}; loop not stored"]
    end
    probe.call('legacy relay cycles cannot crash report aggregation') do
      WtTicketRelay.find_by!(issue_id: issues[:target].id).update!(parent: issues[:entry].id)
      sessions[:manager].get '/work_time/relay_total', params: period
      [sessions[:manager].response.status == 200, "HTTP #{sessions[:manager].response.status}"]
    end
    %w(0 32 abc).each do |invalid|
      probe.call("invalid accounting start day #{invalid} is rejected") do
        before = Setting.plugin_redmine_work_time.deep_dup
        response = post.call(:manager, 'register_project_settings', {account_start_day: invalid})
        [response.status == 400 && Setting.plugin_redmine_work_time == before, "HTTP #{response.status}"]
      end
    end
    probe.call('invalid report date returns HTTP 400') do
      sessions[:employee].get '/work_time/show', params: period.merge(month: 2, day: 31)
      [sessions[:employee].response.status == 400, "HTTP #{sessions[:employee].response.status}"]
    end
    settings = Setting.plugin_redmine_work_time.deep_dup
    settings['account_start_days'][projects[:main].id.to_s] = '31'
    Setting.plugin_redmine_work_time = settings
    {2026 => '2026/02/28 - 2026/03/30', 2028 => '2028/02/29 - 2028/03/30'}.each do |year, boundary|
      probe.call("accounting periods clamp correctly in #{year}") do
        sessions[:manager].get '/work_time/show', params: period.merge(year: year, month: 3, day: 15)
        [sessions[:manager].response.status == 200 && sessions[:manager].response.body.include?(boundary), boundary]
      end
    end
    settings['account_start_days'][projects[:main].id.to_s] = '1'
    Setting.plugin_redmine_work_time = settings
    projects[:main].update_column(:name, '=QA formula-like project')
    ActiveRecord::Base.connection.clear_query_cache
    %w(member_monthly_data member_monthly_data_table total_data total_data_with_act relay_total_data relay_total_data_with_act).each do |action|
      probe.call("#{action} produces parseable CSV") do
        sessions[:manager].get "/work_time/#{action}", params: period
        response = sessions[:manager].response
        rows = CSV.parse(response.body)
        safe_formula = !rows.flatten.compact.any? { |value| value.start_with?('=QA') }
        [response.status == 200 && rows.size > 1 && safe_formula, "HTTP #{response.status}; rows=#{rows.size}"]
      end
    end
    probe.call('standard own-only time visibility also restricts reports') do
      roles[:viewer].update!(time_entries_visibility: 'own')
      sessions[:viewer].get '/work_time/total_data', params: period.merge(user: users[:viewer].id)
      response = sessions[:viewer].response
      [response.status == 200 && CSV.parse(response.body).size == 1, "HTTP #{response.status}; no other member rows"]
    end
    probe.call('AJAX requires login') do
      anonymous = ActionDispatch::Integration::Session.new(Rails.application)
      anonymous.host! 'localhost'
      anonymous.get '/work_time/ajax_add_tickets_input_select', params: period.merge(prj: projects[:main].id)
      [anonymous.response.status == 302 && !anonymous.response.body.include?(issues[:entry].subject),
       "HTTP #{anonymous.response.status}"]
    end
    probe.call('read-only view cannot overwrite the selected member memo') do
      before = WtDailyMemo.find_by(user_id: users[:employee].id, day: date)&.description
      response = post.call(:viewer, 'show', {memo: "Forbidden memo #{suffix}"})
      after = WtDailyMemo.find_by(user_id: users[:employee].id, day: date)&.description
      [response.status == 200 && after == before, "HTTP #{response.status}; memo unchanged"]
    end
    probe.call('malformed time entry values return HTTP 400') do
      response = post.call(:employee, 'index', {time_entry: {own_entry.id.to_s => 'invalid'}})
      [response.status == 400, "HTTP #{response.status}"]
    end
    probe.call('malformed nested entry values return HTTP 400') do
      response = post.call(:employee, 'index', {new_time_entry: {issues[:entry].id.to_s => {'0' => 'invalid'}}})
      [response.status == 400, "HTTP #{response.status}"]
    end
    custom_field = TimeEntryCustomField.create!(name: "QA custom #{suffix}", field_format: 'string', is_required: false)
    probe.call('existing entry custom fields still save') do
      response = post.call(:employee, 'index', {
        time_entry: {own_entry.id.to_s => {hours: '3.5'}},
        "time_entry_#{own_entry.id}" => {custom_field_values: {custom_field.id.to_s => 'QA ÄÖÜ'}}
      })
      [response.status == 200 && own_entry.reload.custom_field_value(custom_field) == 'QA ÄÖÜ',
       "HTTP #{response.status}"]
    end
    probe.call('new entry custom fields still save') do
      response = post.call(:employee, 'index', {
        new_time_entry: {issues[:entry].id.to_s => {'0' => {hours: '0.25', activity_id: activity.id, comments: "Custom #{suffix}"}}},
        "new_time_entry_#{issues[:entry].id}_0" => {custom_field_values: {custom_field.id.to_s => 'QA new custom'}}
      })
      entry = TimeEntry.find_by(comments: "Custom #{suffix}")
      [response.status == 200 && entry&.custom_field_value(custom_field) == 'QA new custom', "HTTP #{response.status}"]
    end
    raise ActiveRecord::Rollback
  end
ensure
  User.current = nil
  Setting.clear_cache
end

failed = results.count { |result| !result[:passed] }
puts "RESULT: #{results.size - failed}/#{results.size} passed, #{failed} failed; temporary records/settings rolled back"
exit(failed.zero? ? 0 : 1)
