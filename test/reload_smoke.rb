# bundle exec rails runner plugins/redmine_work_time/test/reload_smoke.rb
# Checks this plugin's initialization in isolation; changes only this process.
raise 'Use development or test' unless Rails.env.development? || Rails.env.test?
STDOUT.sync = true
Redmine::PluginLoader.singleton_class.prepend(Module.new do
  def directories
    super.select { |directory| File.basename(directory.to_s) == 'redmine_work_time' }
  end
end)
3.times do |iteration|
  Rails.application.reloader.reload!
  count = ProjectsHelper.ancestors.count { |ancestor| ancestor.name == 'WorkTimeProjectsHelperPatch::ProjectsHelperPatch' }
  raise 'Missing or duplicate project settings patch' unless count == 1
  raise 'Wrong registered version' unless Redmine::Plugin.find(:redmine_work_time).version == '0.4.5'
  raise 'Internal relay helper is public' unless WorkTimeController.private_method_defined?(:update_relay)
  puts "PASS: reload #{iteration + 1}: one helper patch, registered version, private relay helper"
end
puts 'PASS: WorkTime reload checks completed'
