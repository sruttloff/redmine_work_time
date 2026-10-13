module WorkTimeProjectsHelperPatch
  module ProjectsHelperPatch
    class << self
      attr_reader :original_project_settings_tabs

      # Called from init.rb right before the module is prepended.
      def capture_original_project_settings_tabs(method)
        @original_project_settings_tabs = method
      end
    end

    def project_settings_tabs
      # Redmine offers no hook for the project settings tabs, so the method has
      # to be wrapped. Other plugins in the wild (redmine_contacts_helpdesk)
      # alias-wrap the same method *after* this module has been prepended, which
      # turns the super chain into a cycle and ends in a 500. On re-entry fall
      # back to the implementation that was in place when this module was
      # prepended, which breaks the cycle.
      if @work_time_resolving_project_settings_tabs
        original = ProjectsHelperPatch.original_project_settings_tabs
        return original ? original.bind(self).call : []
      end

      @work_time_resolving_project_settings_tabs = true
      begin
        tabs = super
        if User.current.allowed_to?(:edit_work_time_total, @project) &&
           tabs.none? {|tab| tab[:name] == 'work_time'}
          tabs << {:name => 'work_time',
                   :controller => 'work_time',
                   :action => :show,
                   :partial => 'settings/work_time_project_settings',
                   :label => :work_time}
        end
        tabs
      ensure
        @work_time_resolving_project_settings_tabs = false
      end
    end
  end
end
