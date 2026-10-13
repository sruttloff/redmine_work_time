require 'redmine'

Redmine::Plugin.register :redmine_work_time do
  name 'Redmine Work Time plugin'
  author 'Tomohisa Kusukawa'
  description 'A plugin to view and update TimeEntry by each user'
  version '0.4.5'
  url 'https://github.com/sruttloff/redmine_work_time'
  author_url 'http://about.me/tkusukawa'

  project_module :work_time do
    permission :view_work_time_tab, {:work_time =>
            [:show, :member_monthly_data, :member_monthly_data_table,
             :ajax_add_tickets_input, :ajax_add_tickets_input_select, :ajax_add_tickets_insert,
             :ajax_done_ratio_input, :ajax_done_ratio_update, :ajax_relay,
            ]}
    permission :view_work_time_other_member, {:work_time =>
            [:show, :member_monthly_data, :member_monthly_data_table,
             :total,:total_data,:relay_total,:relay_total_data,
             :total_data_with_act, :relay_total_data_with_act,
            ]}
    permission :edit_work_time_total, {:work_time => [:register_project_settings, :edit_relay,
      :ajax_relay, :ajax_relay_input, :ajax_relay_input_select]}
    permission :edit_work_time_other_member, {}
  end

  menu :account_menu, :work_time,
    {:controller => 'work_time', :action => 'index'},
    :before => :my_account,
    :caption => :work_time,
    :if => Proc.new{User.current.logged? && Setting.plugin_redmine_work_time['show_account_menu']}

  menu :project_menu, :work_time,
    {:controller => 'work_time', :action => 'show'}, :caption => :work_time,
    :after => :gantt

  settings :default => {'account_start_days' => {}, 'show_account_menu' => 'true'},
           :partial => 'settings/work_time_settings'
end

# Redmine's plugin loader already runs init.rb inside Rails' to_prepare block,
# so the patch is (re)applied after every code reload. Registering another
# Rails.configuration.to_prepare block here would never run: that list has
# already been consumed by the time plugins are loaded, which left the project
# settings tab missing whenever eager loading was off (development, test).
unless ProjectsHelper.ancestors.include?(WorkTimeProjectsHelperPatch::ProjectsHelperPatch)
  # Preserve the current implementation: legacy plugins (redmine_contacts_helpdesk)
  # alias-wrap the prepended method later and would otherwise create a recursive
  # super chain that ends in a 500 on the project settings page.
  WorkTimeProjectsHelperPatch::ProjectsHelperPatch.capture_original_project_settings_tabs(
    ProjectsHelper.instance_method(:project_settings_tabs)
  )
  ProjectsHelper.prepend WorkTimeProjectsHelperPatch::ProjectsHelperPatch
end
