require 'csv'
require 'set'

class WorkTimeController < ApplicationController
  before_action :require_login
  before_action :authorize_work_time_request
  before_action :require_work_time_post
  accept_api_auth :relay_total

  helper :custom_fields
  include CustomFieldsHelper

  NO_ORDER = -1

  def index
    @message = ""
    require_login || return
    @project = nil
    prepare_values
    ticket_pos
    prj_pos
    ticket_del
    hour_update
    make_pack
    update_daily_memo(params[:memo]) if params.key?(:memo)
    Array(@work_time_audit_notes).each { |note| update_daily_memo(note, true) }
    set_holiday
    @custom_fields = TimeEntryCustomField.all
    @link_params.merge!(:action=>"index")
    if !params.key?(:user) then
      redirect_to @link_params
    else
      render "show"
    end
  end

  def show
    @message = ""
    require_login || return
    find_project || return
    authorize || return
    prepare_values
    if @this_user.nil? || !@this_user.allowed_to?(:view_work_time_tab, @project)
      @link_params.merge!(:action=>"relay_total")
      redirect_to @link_params
      return
    end
    ticket_pos
    prj_pos
    ticket_del
    hour_update
    make_pack
    member_add_del_check
    update_daily_memo(params[:memo]) if params.key?(:memo)
    Array(@work_time_audit_notes).each { |note| update_daily_memo(note, true) }
    set_holiday
    @custom_fields = TimeEntryCustomField.all
    @link_params.merge!(:action=>"show")
    if !params.key?(:user) then
      redirect_to @link_params
    end
  end

  def member_monthly_data
    prepare_values
    make_pack
    rows = [['user', 'date', 'project', 'ticket', 'spent time']]
    (@first_date..@last_date).each do |date|
      @month_pack[:odr_prjs].each do |project_pack|
        project_pack[:odr_issues].each do |issue_pack|
          next if issue_pack[:count_hours].zero?
          issue = issue_pack[:issue]
          rows << [@this_user.to_s, date, issue.project.to_s, "##{issue.id} #{issue.subject}",
                   issue_pack[:total_by_day][date]]
        end
      end
      if @month_pack[:other_by_day].key?(date)
        rows << [@this_user.to_s, date, 'PRIVATE', 'PRIVATE', @month_pack[:other_by_day][date]]
      end
    end
    send_work_time_csv(rows, 'member_monthly.csv')
  end

  def member_monthly_data_table
    prepare_values
    make_pack
    dates = (@first_date..@last_date).to_a
    rows = [[''] + dates]
    @month_pack[:odr_prjs].each do |project_pack|
      project_pack[:odr_issues].each do |issue_pack|
        next if issue_pack[:count_hours].zero?
        issue = issue_pack[:issue]
        rows << ["##{issue.id} #{issue.subject}"] + dates.map { |date| issue_pack[:total_by_day][date] }
      end
    end
    send_work_time_csv(rows, 'member_monthly_table.csv')
  end

  def total
    @message = ""
    find_project || return
    authorize || return
    prepare_values
    change_member_position
    change_ticket_position
    change_project_position
    member_add_del_check
    calc_total
    @link_params.merge!(:action=>"total")
  end

  def total_data
    prepare_values
    member_add_del_check
    calc_total
    export_project_csv(relayed: false, activities: false)
  end

  def total_data_with_act
    prepare_values
    member_add_del_check
    calc_total
    export_project_csv(relayed: false, activities: true)
  end

  def edit_relay
    @message = ""
    find_project || return
    authorize || return
    prepare_values
    change_member_position
    change_ticket_position
    change_project_position
    member_add_del_check
    calc_total
    @link_params.merge!(:action=>"edit_relay")
  end

  def relay_total
    @message = ""
    find_project || return
    authorize || return
    prepare_values
    change_member_position
    change_ticket_position
    change_project_position
    member_add_del_check
    calc_total
    respond_to do |format|
	format.html {
	    @link_params.merge!(:action=>"relay_total")
	}
	format.api {}
    end
  end

  def relay_total_data
    prepare_values
    member_add_del_check
    calc_total
    export_project_csv(relayed: true, activities: false)
  end

  def relay_total_data_with_act
    prepare_values
    member_add_del_check
    calc_total
    export_project_csv(relayed: true, activities: true)
  end

  def ajax_relay
    unless params.key?(:issue_id)
      render plain: 'ERROR: no issue_id', layout: false
      return
    end
    issue = visible_work_time_issue!(params[:issue_id])
    @issue_id = issue.id
    @message, @parent_disp, @relay_modified = '', '', false
    if params.key?(:parent_id)
      unless User.current.allowed_to?(:edit_work_time_total, issue.project)
        render_403
        return
      end
      parent_id = params[:parent_id].to_i
      parent_id = issue.parent_id.to_i if parent_id == -1
      visible_work_time_issue!(parent_id) if parent_id.positive?
      update_relay(issue.id, parent_id)
    end
    @parent_id = WtTicketRelay.find_by(issue_id: issue.id)&.parent.to_i
    parent = Issue.visible.find_by(id: @parent_id)
    if parent && can_view_work_time_project?(parent.project)
      @parent_disp = helpers.wk_pretty_issue_name(parent)
    else
      @parent_id = 0
    end
    render layout: false
  end

  def update_relay(issue_id, parent_id)
    raise ActionController::BadRequest, 'Invalid relay target' if parent_id.negative?
    seen = Set.new([issue_id])
    search_id = parent_id
    while search_id.positive?
      if seen.include?(search_id)
        @message = l(:wt_loop_relay)
        return
      end
      seen.add(search_id)
      search_id = WtTicketRelay.find_by(issue_id: search_id)&.parent.to_i
    end
    relay = WtTicketRelay.find_or_initialize_by(issue_id: issue_id)
    relay.position ||= WtTicketRelay.maximum(:position).to_i + 1
    relay.parent = parent_id
    relay.save!
    @relay_modified = true
  end
  private :update_relay

  def ajax_relay_input
    issue = visible_work_time_issue!(params[:issue_id])
    unless User.current.allowed_to?(:edit_work_time_total, issue.project)
      render_403
      return
    end
    @issue_id = issue.id
    @projects = Project.visible.joins('INNER JOIN wt_project_orders ON wt_project_orders.dsp_prj=projects.id AND wt_project_orders.uid=-1').
      select('projects.*, wt_project_orders.dsp_pos as pos').order('pos').to_a.
      select { |project| can_view_work_time_project?(project) }
    render layout: false
  end

  def ajax_relay_input_select
    issue = visible_work_time_issue!(params[:issue_id])
    unless User.current.allowed_to?(:edit_work_time_total, issue.project)
      render_403
      return
    end
    @issue_id = issue.id
    project = Project.visible.find(params[:prj])
    raise ActiveRecord::RecordNotFound unless can_view_work_time_project?(project)
    @issues = Issue.visible.includes(:assigned_to).where(project_id: project.id).order(id: :desc)
    render layout: false
  end

  def ajax_add_tickets_input
    prepare_values
    @select_projects = Project.visible.
        joins("LEFT JOIN wt_project_orders ON wt_project_orders.dsp_prj=projects.id AND wt_project_orders.uid=#{User.current.id}").
        select("projects.*, coalesce(wt_project_orders.dsp_pos,100000) as pos").
        order("pos,name").
        all
    render(:layout=>false)
  end

  def ajax_add_tickets_input_select # 複数チケット選択ウィンドウにAjaxで挿入(Update)される内容を返すアクション
    prepare_values
    project = Project.visible.find(params[:prj])
    raise ActiveRecord::RecordNotFound unless can_view_work_time_project?(project)
    @issues = Issue.visible.
        includes(:assigned_to).
        where(["project_id=:p",{:p=>params[:prj]}]).
        order("id DESC").
        all

    render(:layout=>false)
  end

  def ajax_add_tickets_insert # 日毎工数に挿入するAjaxアクション
    prepare_values

    uid = @this_uid
    @add_issue_id = params[:add_issue].to_i.to_s
    @add_count = params[:count].to_i.to_s
    if @this_uid==@crnt_uid then
      add_issue = Issue.visible.find_by(id: @add_issue_id)
      if add_issue && add_issue.visible? then
        @add_issue_children_cnt = Issue.where(["parent_id = ?", add_issue.id.to_s]).count
        prj = add_issue.project
        if can_view_work_time_project?(prj) && User.current.allowed_to?(:log_time, prj) then
          @activities = []
          @activity_default = nil
          prj.activities.each do |act|
            @activities.push([act.name, act.id])
            @activity_default = act.id if act.is_default
          end

          @custom_fields = TimeEntryCustomField.all

          @add_issue = add_issue

          unless UserIssueMonth.exists?(["uid=:u and issue=:i",{:u=>uid, :i=>@add_issue_id}]) then
            # 既存のレコードが存在していなければ追加
            UserIssueMonth.create(:uid=>uid, :issue=>@add_issue_id,
              :odr => UserIssueMonth.where(["uid = ?", uid]).count + 1
            )
          end
        end
      end
    end

    render(:layout=>false)
  end

  def ajax_done_ratio_input
    prepare_values
    @issue = visible_work_time_issue!(params[:issue_id])
    unless !@issue.closed? && User.current.allowed_to?(:edit_issues, @issue.project)
      render_403
      return
    end
    render layout: false
  end

  def ajax_done_ratio_update
    prepare_values
    @issue = visible_work_time_issue!(params[:issue_id])
    unless !@issue.closed? && User.current.allowed_to?(:edit_issues, @issue.project)
      render_403
      return
    end
    ratio = Integer(params[:done_ratio], exception: false)
    raise ActionController::BadRequest, 'Invalid progress value' unless ratio && (0..100).cover?(ratio)
    @issue.init_journal(User.current)
    @issue.safe_attributes = {'done_ratio' => ratio.to_s}
    @issue.save!
    render layout: false
  end

  def register_project_settings
    day = Integer(params[:account_start_day], exception: false)
    raise ActionController::BadRequest, 'Invalid accounting start day' unless day && (1..31).cover?(day)
    settings = Setting.plugin_redmine_work_time.deep_dup
    settings['account_start_days'] ||= {}
    settings['account_start_days'][@project.id.to_s] = day.to_s
    Setting.plugin_redmine_work_time = settings
    redirect_to controller: 'projects', action: 'settings', id: @project, tab: 'work_time'
  end

private
  def find_project
    # Redmine Pluginとして必要らしいので@projectを設定
    @project = Project.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
    false # callers must return, otherwise rendering happens twice
  end

  def prepare_values
    @crnt_uid = User.current.id
    @this_uid = params[:user].present? ? params[:user].to_i : @crnt_uid
    @this_user = User.find(@this_uid)
    if @this_uid != @crnt_uid
      unless @project && User.current.allowed_to?(:view_work_time_other_member, @project) &&
             @project.users.exists?(@this_uid) && @this_user.allowed_to?(:view_work_time_tab, @project)
        raise ActiveRecord::RecordNotFound
      end
    end
    configured_day = Setting.plugin_redmine_work_time.dig('account_start_days', @project&.id.to_s).to_i
    @account_start_day = (1..31).cover?(configured_day) ? configured_day : 1
    today = Date.current
    year = params.key?(:year) ? params[:year].to_i : today.year
    month = params.key?(:month) ? params[:month].to_i : today.month
    day = params.key?(:day) ? params[:day].to_i : today.day
    begin
      raise Date::Error unless (1..9999).cover?(year)
      @this_date = Date.new(year, month, day)
    rescue Date::Error
      raise ActionController::BadRequest, 'Invalid report date'
    end
    first = accounting_period_start(@this_date.beginning_of_month)
    first = accounting_period_start(@this_date.beginning_of_month.prev_month) if @this_date < first
    @first_date = first
    @last_date = accounting_period_start(first.beginning_of_month.next_month) - 1
    @display_year, @display_month = first.year, first.month
    @last_month, @next_month = @this_date.prev_month, @this_date.next_month
    @restrict_project = false
    if params[:prj].to_i > 0
      project = Project.visible.find(params[:prj])
      raise ActiveRecord::RecordNotFound unless can_view_work_time_project?(project)
      @restrict_project = project.id
    end
    @month_names = l(:wt_month_names).split(',')
    @wday_name = l(:wt_week_day_names).split(',')
    @wday_color = ['#faa', '#eee', '#eee', '#eee', '#eee', '#eee', '#aaf']
    @link_params = {controller: 'work_time', id: @project, year: year, month: month, day: day,
                    user: @this_uid, prj: @restrict_project}
    @is_registerd_backlog = Redmine::Plugin.installed?(:redmine_backlogs)
  end

  def ticket_pos
    return if @this_uid != @crnt_uid

    # 重複削除と順序の正規化
    if order_normalization(UserIssueMonth, :issue, :order=>"odr", :conditions=>["uid=:u",{:u=>@this_uid}]) then
      @message ||= ''
      #@message += '<div style="background:#faa;">Warning: normalize UserIssueMonth</div>'
      return
    end

    # 表示チケット順序変更求処理
    if params.key?("ticket_pos") && params[:ticket_pos] =~ /^(.*)_(.*)$/ then
      tid = $1.to_i
      dst = $2.to_i
      visible_work_time_issue!(tid)
      raise ActionController::BadRequest, 'Invalid display position' unless dst.positive?
      src = UserIssueMonth.where(["uid=:u and issue=:i", {:u=>@this_uid,:i=>tid}]).first
      if src then # ポジション変更の場合
        if src.odr > dst then # チケットを前にもっていく場合
          tgts = UserIssueMonth.
              where(["uid=:u and odr>=:o1 and odr<:o2", {:u=>src.uid, :o1=>dst, :o2=>src.odr}]).
              all
          tgts.each do |tgt|
            tgt.odr += 1; tgt.save# 順位をひとつずつ後へ
          end
          src.odr = dst; src.save
        else # チケットを後に持っていく場合
          tgts = UserIssueMonth.
              where(["uid=:u and odr<=:o1 and odr>:o2",{:u=>src.uid, :o1=>dst, :o2=>src.odr}]).
              all
          tgts.each do |tgt|
            tgt.odr -= 1; tgt.save# 順位をひとつずつ後へ
          end
          src.odr = dst; src.save
        end
      else
        # 新規のポジションの場合
        tgts = UserIssueMonth.
            where(["uid=:u and odr>=:o1", {:u=>@this_uid, :o1=>dst}]).
            all
        tgts.each do |tgt|
          tgt.odr += 1; tgt.save# 順位をひとつずつ後へ
        end
        UserIssueMonth.create(:uid=>@this_uid, :issue=>tid, :odr=>dst) # 追加
      end
    end
  end

  def prj_pos
    return if @this_uid != @crnt_uid

    # 重複削除と順序の正規化
    if order_normalization(WtProjectOrders, :dsp_prj, :order=>"dsp_pos", :conditions=>["uid=:u",{:u=>@this_uid}]) then
      @message ||= ''
      #@message += '<div style="background:#faa;">Warning: normalize WtProjectOrders</div>'
      return
    end

    # 表示プロジェクト順序変更求処理
    if params.key?("prj_pos") && params[:prj_pos] =~ /^(.*)_(.*)$/ then
      tid = $1.to_i
      dst = $2.to_i
      project = Project.visible.find(tid)
      raise ActiveRecord::RecordNotFound unless can_view_work_time_project?(project)
      raise ActionController::BadRequest, 'Invalid display position' unless dst.positive?
      src = WtProjectOrders.
          where(["uid=:u and dsp_prj=:d",{:u=>@this_uid, :d=>tid}]).
          first

      if src then # ポジション変更の場合
        if src.dsp_pos > dst then # チケットを前にもっていく場合
          tgts = WtProjectOrders.
              where(["uid=:u and dsp_pos>=:o1 and dsp_pos<:o2",{:u=>@this_uid, :o1=>dst, :o2=>src.dsp_pos}]).
              all
          tgts.each do |tgt|
            tgt.dsp_pos += 1; tgt.save# 順位をひとつずつ後へ
          end
          src.dsp_pos = dst; src.save
        else # チケットを後に持っていく場合
          tgts = WtProjectOrders.
              where(["uid=:u and dsp_pos<=:o1 and dsp_pos>:o2",{:u=>@this_uid, :o1=>dst, :o2=>src.dsp_pos}]).
              all
          tgts.each do |tgt|
            tgt.dsp_pos -= 1; tgt.save# 順位をひとつずつ後へ
          end
          src.dsp_pos = dst; src.save
        end
      else
        # 新規のポジションの場合
          tgts = WtProjectOrders.
              where(["uid=:u and dsp_pos>=:o1",{:u=>@this_uid, :o1=>dst}]).
              all
          tgts.each do |tgt|
            tgt.dsp_pos += 1; tgt.save# 順位をひとつずつ後へ
          end
          WtProjectOrders.create(:uid=>@this_uid, :dsp_prj=>tid, :dsp_pos=>dst)
      end
    end
  end

  def ticket_del # チケット削除処理
    if params.key?("ticket_del") then
      if params["ticket_del"]=="closed" then # 終了チケット全削除の場合
          issues = Issue.
              joins("INNER JOIN user_issue_months ON user_issue_months.issue=issues.id").
              where(["user_issue_months.uid=:u",{:u=>@this_uid}]).
              all
          issues.each do |issue|
            if issue.closed? then
              tgt = UserIssueMonth.
                  where(["uid=:u and issue=:i",{:u=>@this_uid,:i=>issue.id}]).first
              tgt.destroy
            end
          end
          return
      end

      # チケット番号指定の削除の場合
      src = UserIssueMonth.
          where(["uid=:u and issue=:i",{:u=>@this_uid,:i=>params["ticket_del"]}]).
          first
      if src && src.uid == @crnt_uid then
          tgts = UserIssueMonth.
              where(["uid=:u and odr>:o",{:u=>src.uid, :o=>src.odr}]).
              all
          tgts.each do |tgt|
            tgt.odr -= 1; tgt.save# 当該チケット表示より後ろの全チケットの順位をアップ
          end
          src.destroy# 当該チケット表示を削除
      end
    end
  end

  def hour_update
    return unless request.post?
    by_other = @this_uid != @crnt_uid
    return if by_other && !User.current.allowed_to?(:edit_work_time_other_member, @project)

    (params[:new_time_entry] || {}).each do |issue_id, entries|
      issue = visible_work_time_issue!(issue_id)
      next if @restrict_project && issue.project_id != @restrict_project
      entries.each do |count, values|
        if values[:hours].present?
          next unless User.current.allowed_to?(:log_time, issue.project)
          next if by_other && !User.current.allowed_to?(:log_time_for_other_users, issue.project)
          attributes = values.slice('hours', 'activity_id', 'comments')
          extra = params["new_time_entry_#{issue_id}_#{count}"]
          attributes['custom_field_values'] = extra['custom_field_values'] if extra&.key?('custom_field_values')
          entry = TimeEntry.new(project: issue.project, issue: issue, author: User.current,
                                user: @this_user, spent_on: @this_date)
          entry.safe_attributes = attributes
          if entry.save && by_other
            record_work_time_audit("add time entry of ##{issue.id}: #{entry.hours.to_f}h")
          end
          append_error_message_html(@message, hour_update_check_error(entry, issue.id))
        end
        if values[:remaining_hours].present? || values[:status_id].to_s.start_with?('M')
          append_error_message_html(@message, issue_update_to_remain_and_more(issue.id, values))
        end
      end
    end

    (params[:time_entry] || {}).each do |id, values|
      entry = authorized_time_entry!(id)
      attributes = values.slice('hours', 'activity_id', 'comments')
      extra = params["time_entry_#{id}"]
      attributes['custom_field_values'] = extra['custom_field_values'] if extra&.key?('custom_field_values')
      previous_hours = entry.hours.to_f
      if attributes.key?('hours') && attributes['hours'].blank?
        entry.destroy!
        record_work_time_audit("delete time entry of ##{entry.issue_id}: -#{previous_hours}h-") if by_other
      else
        entry.safe_attributes = attributes
        if entry.save && by_other && entry.hours.to_f != previous_hours
          record_work_time_audit("update time entry of ##{entry.issue_id}: -#{previous_hours}h- #{entry.hours.to_f}h")
        end
        append_error_message_html(@message, hour_update_check_error(entry, entry.issue_id))
      end
      if values[:remaining_hours].present? || values[:status_id].to_s.start_with?('M')
        append_error_message_html(@message, issue_update_to_remain_and_more(entry.issue_id, values))
      end
    end
  end

  def record_work_time_audit(text)
    (@work_time_audit_notes ||= []) << "\n[#{Time.current.strftime('%Y-%m-%d %H:%M')}] #{User.current} #{text}"
  end

  def issue_update_to_remain_and_more(issue_id, vals)
    issue = Issue.find_by_id(issue_id)
    return 'Error: Issue'+issue_id+': Private!' if issue.nil? || !issue.visible?
    return unless User.current.allowed_to?(:edit_issues, issue.project)
    return if vals["remaining_hours"].blank? && vals["status_id"].blank?
    journal = issue.init_journal(User.current)
    # update "0.0" is changed
    vals["remaining_hours"] = 0 if vals["remaining_hours"] == "0.0"
    if vals['status_id'] =~ /^M+(.*)$/
      vals['status_id'] = $1.to_i
    else
      vals.delete 'status_id'
    end
    issue.safe_attributes = vals.slice("remaining_hours", "status_id")
    return if !issue.changed?
    issue.save
    hour_update_check_error(issue, issue_id)
  end

  def append_error_message_html(html, msg)
    return if msg.blank?
    @message = @message.to_s + helpers.content_tag(:div, msg, class: 'wt_error').to_s + '<br>'
  end

  def hour_update_check_error(obj, issue_id)
    return '' if obj.errors.empty?
    helpers.safe_join(["#{l(:field_issue)}##{issue_id}"] + obj.errors.full_messages, helpers.tag.br)
  end

  def member_add_del_check
    # プロジェクトのメンバーを取得
    mem = Member.where(["project_id=:prj", {:prj=>@project.id}]).all
    mem_by_uid = {}
    mem.each do |m|
      next if m.nil? || m.user.nil? || ! m.user.allowed_to?(:view_work_time_tab, @project)
      mem_by_uid[m.user_id] = m
    end

    # メンバーの順序を取得
    odr = WtMemberOrder.where(["prj_id=:p", {:p=>@project.id}]).order("position").all

    # 当月のユーザ毎の工数入力数を取得
    entry_count = TimeEntry.
        where(["spent_on>=:first_date and spent_on<=:last_date",
               {:first_date=>@first_date, :last_date=>@last_date}]).
        select("user_id, count(hours)as cnt").
        group("user_id").
        all
    cnt_by_uid = {}
    entry_count.each do |ec|
      cnt_by_uid[ec.user_id] = ec.cnt
    end

    @members = []
    pos = 1
    # 順序情報にあってメンバーに無いものをチェック
    odr.each do |o|
      if mem_by_uid.has_key?(o.user_id) then
        user=mem_by_uid[o.user_id].user
        if ! user.nil? then
          # 順位の確認と修正
          if o.position != pos then
            o.position=pos
            o.save
          end
          # 表示メンバーに追加
          if user.active? || cnt_by_uid.has_key?(user.id) then
            @members.push([pos, user])
          end
          pos += 1
          # 順序情報に存在したメンバーを削っていく
          mem_by_uid.delete(o.user_id)
          next
        end
      end
      # メンバーに無い順序情報は削除する
      o.destroy
    end

    # 残ったメンバーを順序情報に加える
    mem_by_uid.each do |k,v|
      user = v.user
      next if user.nil?
      n = WtMemberOrder.new(:user_id=>user.id,
                              :position=>pos,
                              :prj_id=>@project.id)
      n.save
      if user.active? || cnt_by_uid.has_key?(user.id) then
        @members.push([pos, user])
      end
      pos += 1
    end
    
  end

  def update_daily_memo(text, append = false)
    return unless request.post?
    return unless @this_uid == @crnt_uid || (append && @project && User.current.allowed_to?(:edit_work_time_other_member, @project))
    memo = WtDailyMemo.find_or_initialize_by(day: @this_date, user_id: @this_uid)
    memo.created_on ||= Time.current
    memo.updated_on = Time.current
    memo.description = append ? memo.description.to_s + text.to_s : text.to_s
    memo.save!
  end

  def set_holiday
    return unless request.post? && User.current.admin?
    if params[:set_holiday].present?
      date = Date.iso8601(params[:set_holiday])
      unless WtHolidays.exists?(holiday: date, deleted_on: nil)
        WtHolidays.create!(holiday: date, created_on: Time.current, created_by: User.current.id)
      end
    end
    if params[:del_holiday].present?
      date = Date.iso8601(params[:del_holiday])
      WtHolidays.where(holiday: date, deleted_on: nil).update_all(deleted_on: Time.current, deleted_by: User.current.id)
    end
  rescue Date::Error
    raise ActionController::BadRequest, 'Invalid holiday date'
  end

  def change_member_position
    ################################### メンバー順序変更処理
    if params.key?("member_pos") && params[:member_pos]=~/^(.*)_(.*)$/ then
      if User.current.allowed_to?(:edit_work_time_total, @project) then
        uid = $1.to_i
        dst = $2.to_i
        mem = WtMemberOrder.where(["prj_id=:p and user_id=:u",{:p=>@project.id, :u=>uid}]).first
        if mem then
          if mem.position > dst then # メンバーを前に持っていく場合
            tgts = WtMemberOrder.
                where(["prj_id=:p and position>=:p1 and position<:p2",{:p=>@project.id, :p1=>dst, :p2=>mem.position}]).
                all
            tgts.each do |mv|
              mv.position+=1; mv.save # 順位を一つずつ後へ
            end
            mem.position=dst; mem.save
          end
          if mem.position < dst then # メンバーを後に持っていく場合
            tgts = WtMemberOrder.
                where(["prj_id=:p and position<=:p1 and position>:p2",{:p=>@project.id, :p1=>dst, :p2=>mem.position}]).
                all
            tgts.each do |mv|
              mv.position-=1; mv.save # 順位を一つずつ前へ
            end
            mem.position=dst; mem.save
          end
        end
      else
        @message ||= ''
        @message += '<div style="background:#faa;">'+l(:wt_no_permission)+'</div>'
        return
      end
    end
  end

  def change_ticket_position
    # 重複削除と順序の正規化
    if order_normalization(WtTicketRelay, :issue_id, :order=>"position") then
      @message ||= ''
      #@message += '<div style="background:#faa;">Warning: normalize WtTicketRelay</div>'
      return
    end

    ################################### チケット表示順序変更処理
    if params.key?("ticket_pos") && params[:ticket_pos]=~/^(.*)_(.*)$/ then
      if User.current.allowed_to?(:edit_work_time_total, @project) then
        issue_id = $1.to_i
        dst = $2.to_i
        issue = visible_work_time_issue!(issue_id)
        raise ActiveRecord::RecordNotFound unless User.current.allowed_to?(:edit_work_time_total, issue.project)
        raise ActionController::BadRequest, 'Invalid display position' unless dst.positive?
        relay = WtTicketRelay.where(["issue_id=:i",{:i=>issue_id}]).first
        if relay then
          if relay.position > dst then # 前に持っていく場合
            tgts = WtTicketRelay.
                where(["position>=:p1 and position<:p2",{:p1=>dst, :p2=>relay.position}]).
                all
            tgts.each do |mv|
              mv.position+=1; mv.save # 順位を一つずつ後へ
            end
            relay.position=dst; relay.save
          end
          if relay.position < dst then # 後に持っていく場合
            tgts = WtTicketRelay.
                where(["position<=:p1 and position>:p2",{:p1=>dst, :p2=>relay.position}]).
                all
            tgts.each do |mv|
              mv.position-=1; mv.save # 順位を一つずつ前へ
            end
            relay.position=dst; relay.save
          end
        end
      else
        @message ||= ''
        @message += '<div style="background:#faa;">'+l(:wt_no_permission)+'</div>'
        return
      end
    end
  end


  def change_project_position
    # 重複削除と順序の正規化
    if order_normalization(WtProjectOrders, :dsp_prj, :order=>"dsp_pos", :conditions=>"uid=-1") then
      @message ||= ''
      #@message += '<div style="background:#faa;">Warning: normalize WtProjectOrders</div>'
      return
    end

    ################################### プロジェクト表示順序変更処理
    return if !params.key?("prj_pos") # 位置変更パラメータが無ければパス
    return if !(params[:prj_pos]=~/^(.*)_(.*)$/) # パラメータの形式が正しくなければパス
    dsp_prj = $1.to_i
    dst = $2.to_i
    project = Project.visible.find(dsp_prj)
    raise ActiveRecord::RecordNotFound unless User.current.allowed_to?(:edit_work_time_total, project)
    raise ActionController::BadRequest, 'Invalid display position' unless dst.positive?

    if !User.current.allowed_to?(:edit_work_time_total, @project) then
       # 権限が無ければパス
      @message ||= ''
      @message += '<div style="background:#faa;">'+l(:wt_no_permission)+'</div>'
      return
    end

    po = WtProjectOrders.where(["uid=-1 and dsp_prj=:d",{:d=>dsp_prj}]).first
    return if po == nil # 対象の表示プロジェクトが無ければパス

    if po.dsp_pos > dst then # 前に持っていく場合
      tgts = WtProjectOrders.where(["uid=-1 and dsp_pos>=:o1 and dsp_pos<:o2",{:o1=>dst, :o2=>po.dsp_pos}]).all
      tgts.each do |mv|
        mv.dsp_pos+=1; mv.save # 順位を一つずつ後へ
      end
      po.dsp_pos=dst; po.save
    end

    if po.dsp_pos < dst then # 後に持っていく場合
      tgts = WtProjectOrders.where(["uid=-1 and dsp_pos<=:o1 and dsp_pos>:o2",{:o1=>dst, :o2=>po.dsp_pos}]).all
      tgts.each do |mv|
        mv.dsp_pos-=1; mv.save # 順位を一つずつ前へ
      end
      po.dsp_pos=dst; po.save
    end
  end

  def calc_total
    ################################################  合計集計計算ループ ########
    @total_cost = 0
    @member_cost = Hash.new
    WtMemberOrder.where(["prj_id=:p",{:p=>@project.id}]).all.each do |i|
      @member_cost[i.user_id] = 0
    end
    @issue_parent = Hash.new # clear cash

    @issue_cost = Hash.new
    @r_issue_cost = Hash.new

    @prj_cost = Hash.new
    @r_prj_cost = Hash.new

    @issue_act_cost = Hash.new
    @r_issue_act_cost = Hash.new

    relay = Hash.new
    WtTicketRelay.all.each do |i|
      relay[i.issue_id] = i.parent
    end

    #当月の時間記録を抽出
    TimeEntry.visible(User.current).
        where(["spent_on>=:t1 and spent_on<=:t2 and hours>0",{:t1 => @first_date, :t2 => @last_date}]).
        all.
        each do |time_entry|
      iid = time_entry.issue_id
      uid = time_entry.user_id
      next unless can_view_member_time?(uid, time_entry.project)
      # Redmine 6.1 returns TimeEntry#hours as a Rational. Keep a Float here so
      # the sums below do not end up as "19/4" in the CSV and API output.
      cost = time_entry.hours.to_f
      act = time_entry.activity_id
      # 本プロジェクトのユーザの工数でなければパス
      next unless @member_cost.key?(uid)

      issue = Issue.find_by_id(iid)
      next if issue.nil? # チケットが削除されていたらパス
      pid = issue.project_id
      # プロジェクト限定の対象でなければパス
      next if @restrict_project && pid != @restrict_project

      @total_cost += cost
      @member_cost[uid] += cost

      parent_iid = get_parent_issue(relay, iid)
      if !Issue.find_by_id(iid) || !Issue.find_by_id(iid).visible?
        # 表示権限の無い工数があった場合
        iid = -1 # private
        pid = -1 # private
        act = -1 # private
      end
      @issue_cost[iid] ||= Hash.new
      @issue_cost[iid][-1] ||= 0
      @issue_cost[iid][-1] += cost
      @issue_cost[iid][uid] ||= 0
      @issue_cost[iid][uid] += cost

      @prj_cost[pid] ||= Hash.new
      @prj_cost[pid][-1] ||= 0
      @prj_cost[pid][-1] += cost
      @prj_cost[pid][uid] ||= 0
      @prj_cost[pid][uid] += cost

      @issue_act_cost[iid] ||= Hash.new
      @issue_act_cost[iid][uid] ||= Hash.new
      @issue_act_cost[iid][uid][act] ||= 0
      @issue_act_cost[iid][uid][act] += cost

      parent_issue = Issue.find_by_id(parent_iid)
      if parent_issue && parent_issue.visible?
        parent_pid = parent_issue.project_id
      else
        parent_iid = -1
        parent_pid = -1
      end

      @r_issue_cost[parent_iid] ||= Hash.new
      @r_issue_cost[parent_iid][-1] ||= 0
      @r_issue_cost[parent_iid][-1] += cost
      @r_issue_cost[parent_iid][uid] ||= 0
      @r_issue_cost[parent_iid][uid] += cost

      @r_prj_cost[parent_pid] ||= Hash.new
      @r_prj_cost[parent_pid][-1] ||= 0
      @r_prj_cost[parent_pid][-1] += cost
      @r_prj_cost[parent_pid][uid] ||= 0
      @r_prj_cost[parent_pid][uid] += cost

      @r_issue_act_cost[parent_iid] ||= Hash.new
      @r_issue_act_cost[parent_iid][uid] ||= Hash.new
      @r_issue_act_cost[parent_iid][uid][act] ||= 0
      @r_issue_act_cost[parent_iid][uid][act] += cost
    end
  end

  def get_parent_issue(relay, iid)
    @issue_parent ||= {}
    return @issue_parent[iid] if @issue_parent.key?(iid)
    path = Set.new
    current = iid
    loop do
      return @issue_parent[iid] = iid if path.include?(current)
      path.add(current)
      issue = Issue.find_by(id: current)
      return @issue_parent[iid] = 0 unless issue
      # Report metadata contains no grants; it is derived from visible entries.
      unless relay.key?(current)
        WtTicketRelay.create!(issue_id: current, position: WtTicketRelay.maximum(:position).to_i + 1, parent: 0)
        relay[current] = 0
      end
      if issue.visible? && can_view_work_time_project?(issue.project)
        WtProjectOrders.find_or_create_by!(uid: -1, dsp_prj: issue.project_id) do |order|
          order.dsp_pos = WtProjectOrders.where(uid: -1).maximum(:dsp_pos).to_i + 1
        end
      end
      parent = relay[current].to_i
      break if parent.zero? || parent == current
      current = parent
    end
    @issue_parent[iid] = current
  end

  def make_pack
    # 月間工数表のデータを作成
    @month_pack = {:ref_prjs=>{}, :odr_prjs=>[],
                   :total=>0, :total_by_day=>{},
                   :other=>0, :other_by_day=>{},
                   :count_prjs=>0, :count_issues=>0}
    @month_pack[:total_by_day].default = 0

    # 日毎工数のデータを作成
    @day_pack = {:ref_prjs=>{}, :odr_prjs=>[],
                 :total=>0, :total_by_day=>{},
                 :other=>0, :other_by_day=>{},
                 :count_prjs=>0, :count_issues=>0}
    @day_pack[:total_by_day].default = 0

    # プロジェクト順の表示データを作成
    dsp_prjs = Project.visible.joins("INNER JOIN wt_project_orders ON wt_project_orders.dsp_prj=projects.id").
        where(["wt_project_orders.uid=:u",{:u=>@this_uid}]).
        select("projects.*, wt_project_orders.dsp_pos as dsp_pos").
        order("wt_project_orders.dsp_pos").
        all
    dsp_prjs.each do |prj|
      next unless can_view_member_time?(@this_uid, prj)
      next if @restrict_project && @restrict_project!=prj.id
      make_pack_prj(@month_pack, prj, prj.dsp_pos)
      make_pack_prj(@day_pack, prj, prj.dsp_pos)
    end
    @prj_odr_max = dsp_prjs.length

    # チケット順の表示データを作成
    dsp_issues = Issue.visible.joins("INNER JOIN user_issue_months ON user_issue_months.issue=issues.id").
        where(["user_issue_months.uid=:u",{:u=>@this_uid}]).
        order("user_issue_months.odr").
        select("issues.*, user_issue_months.odr").
        all
    dsp_issues.each do |issue|
      next unless can_view_member_time?(@this_uid, issue.project)
      next if @restrict_project && @restrict_project!=issue.project.id
      month_prj_pack = make_pack_prj(@month_pack, issue.project)
      make_pack_issue(month_prj_pack, issue, issue.odr)
      day_prj_pack = make_pack_prj(@day_pack, issue.project)
      make_pack_issue(day_prj_pack, issue, issue.odr)
    end
    @issue_odr_max = dsp_issues.length

    # 月内の工数を集計
    hours = TimeEntry.visible(User.current).
        includes(:issue).
        where(["user_id=:uid and spent_on>=:day1 and spent_on<=:day2",
               {:uid => @this_uid, :day1 => @first_date, :day2 => @last_date}]).
        all
    hours.each do |hour|
      next if @restrict_project && @restrict_project!=hour.project.id
      next unless can_view_member_time?(hour.user_id, hour.project)
      work_time = hour.hours.to_f # Rational since Redmine 6.1, see calc_total
      if hour.issue && hour.issue.visible? then
        # 表示項目に工数のプロジェクトがあるかチェック→なければ項目追加
        prj_pack = make_pack_prj(@month_pack, hour.project)

        # 表示項目に工数のチケットがあるかチェック→なければ項目追加
        issue_pack = make_pack_issue(prj_pack, hour.issue)

        issue_pack[:count_hours] += 1

        # 合計時間の計算
        @month_pack[:total] += work_time
        prj_pack[:total] += work_time
        issue_pack[:total] += work_time

        # 日毎の合計時間の計算
        date = hour.spent_on
        @month_pack[:total_by_day][date] += work_time
        prj_pack[:total_by_day][date] += work_time
        issue_pack[:total_by_day][date] += work_time

        if date==@this_date then # 表示日の工数であれば項目追加
          # 表示項目に工数のプロジェクトがあるかチェック→なければ項目追加
          day_prj_pack = make_pack_prj(@day_pack, hour.project)

          # 表示項目に工数のチケットがあるかチェック→なければ項目追加
          day_issue_pack = make_pack_issue(day_prj_pack, hour.issue, NO_ORDER)

          day_issue_pack[:each_entries][hour.id] = hour # 工数エントリを追加
          day_issue_pack[:total] += work_time
          day_prj_pack[:total] += work_time
          @day_pack[:total] += work_time
        end
      else
        # 合計時間の計算
        @month_pack[:total] += work_time
        @month_pack[:other] += work_time

        # 日毎の合計時間の計算
        date = hour.spent_on
        @month_pack[:total_by_day][date] ||= 0
        @month_pack[:total_by_day][date] += work_time
        @month_pack[:other_by_day][date] ||= 0
        @month_pack[:other_by_day][date] += work_time

        if date==@this_date then # 表示日の工数であれば項目追加
          @day_pack[:total] += work_time
          @day_pack[:other] += work_time
        end
      end
    end

    # この日のチケット作成を洗い出す
    next_date = @this_date+1
    t1 = Time.local(@this_date.year, @this_date.month, @this_date.day)
    t2 = Time.local(next_date.year, next_date.month, next_date.day)
    issues = Issue.where(["(author_id = :u and created_on >= :t1 and created_on < :t2) or "+
                              "id in (select journalized_id from journals where journalized_type = 'Issue' and "+
                              "user_id = :u and created_on >= :t1 and created_on < :t2 group by journalized_id)",
                          {:u => @this_user, :t1 => t1, :t2 => t2}]).all

    issues.each do |issue|
      next unless can_view_member_time?(@this_uid, issue.project)
      next if @restrict_project && @restrict_project!=issue.project.id
      next if !@this_user.allowed_to?(:log_time, issue.project)
      next if !issue.visible?
      prj_pack = make_pack_prj(@day_pack, issue.project)
      issue_pack = make_pack_issue(prj_pack, issue)
      if issue_pack[:css_classes] == 'wt_iss_overdue'
        issue_pack[:css_classes] = 'wt_iss_overdue_worked'
      else
        issue_pack[:css_classes] = 'wt_iss_worked'
      end
    end
    issues = Issue.
        joins("INNER JOIN issue_statuses ist on ist.id = issues.status_id ").
        joins("LEFT JOIN groups_users on issues.assigned_to_id = group_id").
        where(["1 = 1 and
                (  (issues.assigned_to_id = :u or groups_users.user_id = :u) and
                   issues.start_date < :t2 and
                   ist.is_closed = :closed
                )", {:u => @this_uid, :t2 => t2, :closed => false}]).
        all
    issues.each do |issue|
      next unless can_view_member_time?(@this_uid, issue.project)
      next if @restrict_project && @restrict_project!=issue.project.id
      next if !@this_user.allowed_to?(:log_time, issue.project)
      next if !issue.visible?
      prj_pack = make_pack_prj(@day_pack, issue.project)
      issue_pack = make_pack_issue(prj_pack, issue)
      if issue_pack[:css_classes] == 'wt_iss_default'
        issue_pack[:css_classes] = 'wt_iss_assigned'
      elsif issue_pack[:css_classes] == 'wt_iss_worked'
        issue_pack[:css_classes] = 'wt_iss_assigned_worked'
      elsif issue_pack[:css_classes] == 'wt_iss_overdue'
        issue_pack[:css_classes] = 'wt_iss_assigned_overdue'
      elsif issue_pack[:css_classes] == 'wt_iss_overdue_worked'
        issue_pack[:css_classes] = 'wt_iss_assigned_overdue_worked'
      end
    end

    # 月間工数表から工数が無かった項目の削除と項目数のカウント
    @month_pack[:count_issues] = 0
    @month_pack[:odr_prjs].each do |prj_pack|
      prj_pack[:odr_issues].each do |issue_pack|
        if issue_pack[:count_hours]==0 then
          prj_pack[:count_issues] -= 1
        end
      end

      if prj_pack[:count_issues]==0 then
        @month_pack[:count_prjs] -= 1
      else
        @month_pack[:count_issues] += prj_pack[:count_issues]
      end
    end
  end

  def make_pack_prj(pack, new_prj, odr=NO_ORDER)
      # 表示項目に当該プロジェクトがあるかチェック→なければ項目追加
      unless pack[:ref_prjs].has_key?(new_prj.id) then
        prj_pack = {:odr=>odr, :prj=>new_prj,
                    :total=>0, :total_by_day=>{},
                    :ref_issues=>{}, :odr_issues=>[], :count_issues=>0}
        pack[:ref_prjs][new_prj.id] = prj_pack
        pack[:odr_prjs].push prj_pack
        pack[:count_prjs] += 1
        prj_pack[:total_by_day].default = 0
      end
      pack[:ref_prjs][new_prj.id]
  end

  def make_pack_issue(prj_pack, new_issue, odr=NO_ORDER)
      id = new_issue.nil? ? -1 : new_issue.id
      # 表示項目に当該チケットがあるかチェック→なければ項目追加
      unless prj_pack[:ref_issues].has_key?(id) then
        issue_pack = {:odr=>odr, :issue=>new_issue,
                      :total=>0, :total_by_day=>{},
                      :count_hours=>0, :each_entries=>{},
                      :cnt_childrens=>0}
        issue_pack[:total_by_day].default = 0
        if !new_issue.due_date.nil? && new_issue.due_date < @this_date.to_datetime
          issue_pack[:css_classes] = 'wt_iss_overdue'
        else
          issue_pack[:css_classes] = 'wt_iss_default'
        end
        prj_pack[:ref_issues][id] = issue_pack
        prj_pack[:odr_issues].push issue_pack
        prj_pack[:count_issues] += 1
        cnt_childrens = Issue.where(["parent_id = ?", new_issue.id.to_s]).count
        issue_pack[:cnt_childrens] = cnt_childrens
      end
      prj_pack[:ref_issues][id]
  end

  def sum_or_nil(v1, v2)
    if v2.blank?
      v1
    else
      if v1.blank?
        v2
      else
        v1 + v2
      end
    end
  end

  # 重複削除と順序の正規化
  def order_normalization(table, key_column, find_params)
    raise "need table" unless table
    order = find_params[:order]
    raise "need :order" unless order
    update = false

    tgts = table.
        where(find_params[:conditions]).
        order(order).
        all
    keys = []
    tgts.each do |tgt|
      if keys.include?(tgt[key_column]) then
        tgt.destroy
        update = true
      else
        keys.push(tgt[key_column])
        if tgt[order] != keys.length then
          tgt[order] = keys.length
          tgt.save
          update = true
        end
      end
    end
    update
  end

  def can_view_work_time_project?(project)
    project && project.visible? && (User.current.allowed_to?(:view_work_time_tab, project) ||
                                   User.current.allowed_to?(:view_work_time_other_member, project))
  end

  def can_view_member_time?(user_id, project)
    can_view_work_time_project?(project) && (user_id == User.current.id ||
      User.current.allowed_to?(:view_work_time_other_member, project))
  end

  def visible_work_time_issue!(id)
    issue = Issue.visible.find(id)
    raise ActiveRecord::RecordNotFound unless can_view_work_time_project?(issue.project)
    issue
  end

  def authorize_work_time_request
    @project = nil
    if params[:id].present?
      return unless find_project
      unless can_view_work_time_project?(@project)
        render_403
        return
      end
    end
    project_actions = %w(show total total_data total_data_with_act edit_relay relay_total
                         relay_total_data relay_total_data_with_act register_project_settings ajax_relay)
    if project_actions.include?(action_name) && !@project
      render_404
      return
    end
    if %w(register_project_settings edit_relay).include?(action_name) &&
       !User.current.allowed_to?(:edit_work_time_total, @project)
      render_403
      return
    end
    report_actions = %w(total total_data total_data_with_act relay_total relay_total_data relay_total_data_with_act)
    if report_actions.include?(action_name) && !User.current.allowed_to?(:view_work_time_other_member, @project)
      render_403
      return
    end
    @project = nil if action_name == 'index'
    prepare_values
    if params[:time_entry].present?
      validate_work_time_fields!(params[:time_entry])
      params[:time_entry].each_pair do |id, values|
        validate_work_time_fields!(values)
        authorized_time_entry!(id)
      end
    end
    if params[:new_time_entry].present?
      validate_work_time_fields!(params[:new_time_entry])
      params[:new_time_entry].each_pair do |id, entries|
        validate_work_time_fields!(entries)
        visible_work_time_issue!(id)
        entries.each_pair { |_, values| validate_work_time_fields!(values) }
      end
    end
    params.each_pair do |key, values|
      validate_work_time_fields!(values) if key.match?(/\A(?:new_)?time_entry_\d/)
    end
    if (params.key?(:set_holiday) || params.key?(:del_holiday)) && !User.current.admin?
      render_403
    end
  end

  def validate_work_time_fields!(fields)
    raise ActionController::BadRequest, 'Invalid time entry fields' unless fields.is_a?(ActionController::Parameters)
  end

  def authorized_time_entry!(id)
    entry = TimeEntry.find(id)
    unless entry.user_id == @this_uid && entry.spent_on == @this_date &&
           entry.editable_by?(User.current) && can_view_work_time_project?(entry.project) &&
           (!@restrict_project || entry.project_id == @restrict_project) &&
           (@this_uid == @crnt_uid || (@project && User.current.allowed_to?(:edit_work_time_other_member, @project)))
      raise ActiveRecord::RecordNotFound
    end
    entry
  end

  def require_work_time_post
    mutations = %w(time_entry new_time_entry memo set_holiday del_holiday ticket_pos prj_pos
                   ticket_del member_pos parent_id)
    writes = %w(ajax_add_tickets_insert ajax_done_ratio_update register_project_settings)
    if !request.post? && (writes.include?(action_name) || mutations.any? { |key| params.key?(key) })
      response.set_header('Allow', 'POST')
      head :method_not_allowed
    end
  end

  def accounting_period_start(month)
    month.change(day: [@account_start_day, month.end_of_month.day].min)
  end

  def send_work_time_csv(rows, filename)
    data = CSV.generate do |csv|
      rows.each do |row|
        csv << row.map do |value|
          value.is_a?(String) && value.match?(/\A(?:[[:space:]]*[=+\-@]|[\t\r\n])/) ? "'#{value}" : value
        end
      end
    end
    send_data Redmine::CodesetUtil.from_utf8(data, l(:general_csv_encoding)), type: 'text/csv', filename: filename
  end

  def export_project_csv(relayed:, activities:)
    header = ['user']
    header += ['relayed project', 'relayed ticket'] unless relayed
    header += ['project', 'ticket']
    header << 'activity' if activities
    rows = [header + ['spent time']]
    costs = if activities
      relayed ? @r_issue_act_cost : @issue_act_cost
    else
      relayed ? @r_issue_cost : @issue_cost
    end
    @members.each do |_, user|
      costs.each do |issue_id, member_costs|
        next unless member_costs.key?(user.id)
        issue = Issue.visible.find_by(id: issue_id)
        labels = issue ? [issue.project.to_s, "##{issue.id} #{issue.subject}"] : ['private', 'private']
        unless relayed
          parent = Issue.visible.find_by(id: @issue_parent[issue_id])
          labels = (parent ? [parent.project.to_s, "##{parent.id} #{parent.subject}"] : ['private', 'private']) + labels
        end
        if activities
          member_costs[user.id].each do |activity_id, hours|
            name = issue ? (TimeEntryActivity.find_by(id: activity_id)&.name || 'nil') : 'private'
            rows << [user.to_s] + labels + [name, hours]
          end
        elsif member_costs[user.id] != 0
          rows << [user.to_s] + labels + [member_costs[user.id]]
        end
      end
    end
    filename = relayed ? 'monthly_report' : 'monthly_report_raw'
    filename += '_with_act' if activities
    send_work_time_csv(rows, "#{filename}.csv")
  end

end
