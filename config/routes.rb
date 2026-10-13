# Explicit routes instead of the former "work_time/:action" catch-all.
#
# A dynamic :action segment is deprecated since Rails 7.1 ("will be removed in
# Rails 7.2") and it turned every public controller method into a reachable
# action. The generated paths are identical to the ones the catch-all produced,
# so existing links, bookmarks and the plugin's own JavaScript keep working.
RedmineApp::Application.routes.draw do
  %w(
    index
    show
    member_monthly_data
    member_monthly_data_table
    total
    total_data
    total_data_with_act
    edit_relay
    relay_total
    relay_total_data
    relay_total_data_with_act
    ajax_relay
    ajax_relay_input
    ajax_relay_input_select
    ajax_add_tickets_input
    ajax_add_tickets_input_select
    ajax_add_tickets_insert
    ajax_done_ratio_input
    ajax_done_ratio_update
    register_project_settings
  ).each do |work_time_action|
    match "work_time/#{work_time_action}",
          :to => "work_time##{work_time_action}",
          :via => [:get, :post],
          :as => "work_time_#{work_time_action}"
    match "work_time/#{work_time_action}/:id",
          :to => "work_time##{work_time_action}",
          :via => [:get, :post],
          :as => "work_time_#{work_time_action}_project"
  end
end
