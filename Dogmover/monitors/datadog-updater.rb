require 'json'
require 'uri'
require 'pry'

# needed for parsing our input spreadsheet
require 'rubyXL'
require 'rubyXL/convenience_methods'

# significantly more straightforward way of writing new spreadsheets
require 'spreadsheet'

require 'datadog_api_client'

require './lib/alerts.rb'

DEBUG = ENV['DEBUG'] == 'true'
PRY   = ENV['PRY'] == 'true'
PAGERDUTY = ENV['PAGERDUTY'] == 'true'

START_TIME = Time.now.strftime("%Y-%m-%d-%H%M%S")

REALLY_UPDATE_DATADOG = ENV['DRY_RUN'] == 'false'

DatadogAPIClient.configure do |config|
  config.debugging = true if ENV['DATADOG_DEBUG'] == 'true'
end

local_alert_defs = Dir.children('.').filter{|c| c =~ /.*\.json$/ && File.stat(c).file? }
local_alerts = local_alert_defs.collect do |alert_def|
  Alert.new(File.read(alert_def))
end.sort_by(&:alert_id)

# completely ignore the default 'ntp' alert that datadog generated
local_alerts = local_alerts.select{|alert| alert.alert_id != 3618226}

#latest_exported_workbook = "./current-alert-status-10312022.xlsx"
latest_exported_workbook = "./current-alert-status-11292022.xlsx"

input_workbook = latest_exported_workbook

if ENV['TEST'] == 'true'
  test_alert_ids = [102037107]
  test_workbook = "test-alert-status.xlsx" 
  input_workbook = test_workbook
end

puts "Using input workbook #{input_workbook}"
# exported from the google sheet that EMs have been putting new mappings into
exported_workbook = RubyXL::Parser.parse(input_workbook)

workbook_alerts = local_alerts.collect do |alert|
  get_alert_from_workbook(alert.alert_id, exported_workbook, alert)
end.compact

workbook_alerts.reject!{|x| ! test_alert_ids.include?(x.alert_id)} if ENV['TEST'] == 'true'

TEAM_TO_PROCESS = ENV['TEAM']
if TEAM_TO_PROCESS.nil? || TEAM_TO_PROCESS.empty?
  puts "Was not requested to update only a specific team's alerts, proceeding with all"
else
  puts "Requested updates only for team #{TEAM_TO_PROCESS}"
  workbook_alerts.reject!{|x| x.new_team != TEAM_TO_PROCESS }
end

puts "Amount of relevant alerts found in workbook: #{workbook_alerts.count}"

inconsistent_alerts = []
workbook_inconsistent = local_alerts.any? do |local_alert|
  workbook_alert = get_alert(local_alert.alert_id, workbook_alerts)
  if ! workbook_alert
    # no matching alert- that's fine
    false
  elsif workbook_alert.message == local_alert.message && \
      workbook_alert.query == local_alert.query && \
      workbook_alert.name == local_alert.name && \
      workbook_alert.tags == local_alert.tags
    false
  else
    puts "#{local_alert.alert_id}: inconsistent query/name/tags between curent alerts and worksheet"
    inconsistent_alerts << local_alert.alert_id
    workbook_alert.update_message_from(local_alert)
    workbook_alert.update_query_from(local_alert)
    workbook_alert.update_tags_from(local_alert)
    binding.pry if (DEBUG && PRY)
    true
  end
end

puts "Reprocessing alerts with data from latest workbook..."
workbook_alerts.each{|x| x.reprocess_alert}

puts ''
puts 'SANITY CHECKS'
puts 'Complete set of new alert owners: '
new_alert_owners = workbook_alerts.collect{|x| "#{[x.new_team,x.new_squad].join(' > ')}"}.compact.uniq.sort
puts new_alert_owners.join("\n")
puts ''

puts "Raw owner names that still need to be mapped to teams/squads:"
owners_that_need_remapping = workbook_alerts.collect do |x|
  if x.new_team.nil? && x.raw_new_owner
    x.raw_new_owner.downcase
  end
end.compact.uniq

puts owners_that_need_remapping.join("\n")


# find alerts that may be missing entirely from the workbook that existed during the original export
missing_alerts            = get_missing_alerts(local_alerts, workbook_alerts)

# find alerts with a nil value for 'new owner' - probably already owned
alerts_with_no_new_owner = workbook_alerts.select{|alert| alert.new_team.nil?}
completely_unowned       = alerts_with_no_new_owner.select{|alert| ! alert.tags.any?{|t| t =~ /team/}}.compact

# complete list of team tags from the 'alerts with no "new" owner' set:
# alerts_with_no_new_owner.collect{|x| x.tags.select{|t| t =~ /team/}}.flatten.uniq
# ["team:platform", "team:iam", "team:data", "team:notifications", "team:devx", "team:cloud-engineering", "team:messaging"]
#   these look safe to me
completely_unowned_log = "./completely_unowned.log"
puts "Amount of completely unowned alerts (including no team tag) set: #{completely_unowned.count}"
puts "Writing set of unowned alerts to #{completely_unowned_log}"
File.write(completely_unowned_log, completely_unowned.collect{|x| "#{x.alert_id} - #{x.name}"}.join("\n"))

# set of alerts we've been asked to remove entirely
alerts_to_remove = workbook_alerts.select{|x| x.to_delete == true}
alerts_to_remove_ids = alerts_to_remove.collect{|x| x.alert_id}
delete_request_log = './to_delete.log'
puts "Amount of alerts requested to be deleted: #{alerts_to_remove_ids.count}"
puts "Writing delete-able alert set to #{delete_request_log}"
File.write(delete_request_log, alerts_to_remove.collect{|x| "#{x.alert_id} - #{x.name}"}.join("\n"))

# alerts that are still set to a 'shared' owner
shared_alerts    = workbook_alerts.select do |x|
  if x.new_team
    x.new_team == 'shared-monolith' || x.new_team == 'service-owner'
  else
    nil
  end
end
shared_ids = shared_alerts.collect{|x| x.alert_id}
shared_alert_log = "./shared_alerts.log"
puts "Size of 'shared' unowned alerts set: #{shared_ids.count}"
puts "Writing shared unowned alert set to #{shared_alert_log}"
File.write(shared_alert_log, shared_alerts.collect{|x| "#{x.alert_id} - #{[x.new_team, x.new_squad].join('>')} - #{x.name}"}.compact.join("\n"))
puts 'END OF SANITY CHECKS'
puts ''

puts "Excluding alerts that do not have diffs from the desired and actual state..."
workbook_alerts.reject!{|x| ! alert_diff(x.alert_id, local_alerts, workbook_alerts)}

puts "Initial amount of alerts that will need to be updated: #{workbook_alerts.count}"

# terraform-managed alerts that will need updates
terraform_fixup_log = "./to_fix_in_terraform.log"
puts "Writing terraform-managed alerts that will need updates to #{terraform_fixup_log}"
terraform_alerts = workbook_alerts.select{|x| x.terraform?}
File.write(terraform_fixup_log, terraform_alerts.collect{|x| "#{x.alert_id} - #{[x.new_team, x.new_squad].join('>')} - #{x.name}"}.compact.join("\n"))
puts ''

# alerts with multiple slack channel pairings with potential conditionals that are both not terraformed 
# and also do not reference the deprecated UK alerts channel
# (same should be done for paging channels)
non_terraform_non_uk_multialerts = workbook_alerts.select do |x|
    x.alerts.reject{|x| x == '@slack-incidents-uk' }.count > 1
  end.select do |x|
    x.alerts_in_conditionals?
  end.select do |x|
    ! x.terraform?
  end

multialertcount = non_terraform_non_uk_multialerts.count
multialert_ids  = non_terraform_non_uk_multialerts.collect{|x| x.alert_id}

puts "Size of set of alerts that target multiple slack channels (excluding UK or terraform-managed): #{multialertcount}"
multi_fixup_log     = "./multi_alert_channels_to_fix_manually.txt"
puts "Writing alerts that need manual adjustments to #{multi_fixup_log}"
File.write(multi_fixup_log, non_terraform_non_uk_multialerts.collect{|x| "#{x.alert_id} - #{[x.new_team, x.new_squad].join('>')} - #{x.name}"}.compact.join("\n"))
puts ''

puts "Finalizing the set of alerts to update..."

puts "Excluding alerts that can not be programmatically updated (from the multi-alert set above)..."
workbook_alerts.reject!{|x| multialert_ids.include?(x.alert_id)}

puts "Excluding terraform alerts..."
workbook_alerts.reject!{|x| x.terraform? }

puts "Excluding 'shared' alerts that need more help..."
workbook_alerts.reject!{|x| shared_ids.include?(x.alert_id)}

puts "Excluding set of alerts that people wanted to delete..."
workbook_alerts.reject!{|x| alerts_to_remove_ids.include?(x.alert_id)}

puts "Excluding alerts meant for deletion..."
workbook_alerts.reject!{|x| x.to_delete == true }

puts "Final amount of alerts to update: #{workbook_alerts.count}"

binding.pry if (DEBUG && PRY)

def report_diff(spreadsheet, workbook_name, new_alert_configs, old_alert_configs)
  output_sheet = spreadsheet.create_worksheet(name: workbook_name)
  new_message_col_name = if workbook_name =~ /terraform|multi/
                           'Proposed New Message (SUGGESTION ONLY)'
                         else
                           'New Message'
                         end
  output_sheet.row(0).concat(['Datadog Alert ID', 'New Team', 'New Squad', 'Alert Name', 'New Alert Slack Channel', 'New Pagerduty Service', 'Update Slack?', 'Update Pagerduty?', 'Original Message', new_message_col_name])
  new_alert_configs.each_with_index do |new_alert, i|
    alert_id          = new_alert.alert_id
    old_alert         = get_alert(alert_id, old_alert_configs)
    new_team          = new_alert.new_team
    new_squad         = new_alert.new_squad
    alert_name        = new_alert.name
    new_slack_channel = new_alert.new_slack_channel
    new_pagerduty_service = new_alert.new_pagerduty_service
    # as of nov. 1
    update_slack      = true
    update_pagerduty  = PAGERDUTY
    original_message  = old_alert.message
    new_message       = new_alert.message
    output_sheet.row(i+1).concat [alert_id, new_team, new_squad, alert_name, new_slack_channel, new_pagerduty_service, update_slack, update_pagerduty, original_message, new_message]
  end
end

Spreadsheet.client_encoding = 'UTF-8'
report_workbook = Spreadsheet::Workbook.new
report_workbook_file = if TEAM_TO_PROCESS.nil? || TEAM_TO_PROCESS.empty?
                         "./report-update-summary-#{START_TIME}.xls"
                       else
                         "./report-update-summary-#{START_TIME}-#{TEAM_TO_PROCESS}.xls"
                       end

report_diff(report_workbook, 'Alerts that will be Automatically Changed', workbook_alerts, local_alerts)
report_diff(report_workbook, 'Terraform Alerts to Fix',  terraform_alerts, local_alerts)
report_diff(report_workbook, 'Multi-Channel Alerts to Fix',  non_terraform_non_uk_multialerts, local_alerts)
report_diff(report_workbook, 'Alerts to Remove',  alerts_to_remove, local_alerts)
report_diff(report_workbook, 'Shared Alerts - No Updates', shared_alerts, local_alerts)
report_diff(report_workbook, 'Completely Unowned Alerts - No Updates', completely_unowned, local_alerts)
report_workbook.write(report_workbook_file)
puts "Wrote summary of updates to happen to #{report_workbook_file}"

puts 'Complete set of teams that will be processed:'
new_alert_owners = workbook_alerts.collect{|x| x.new_team}.compact.uniq.sort
puts new_alert_owners.join("\n")
puts ''

def attempt_datadog_updates(workbook_alerts, local_alerts, report_workbook, monitor_client)
  output_sheet = report_workbook.create_worksheet(name: 'Alerts that have been updated')
  output_sheet.row(0).concat(['Datadog Alert ID', 'Status', 'New Team', 'New Squad', 'Alert Name', 'New Alert Slack Channel', 'New Pagerduty Service', 'Update Slack?', 'Update Pagerduty?', 'Original Message', 'New Message'])
  i = 1
  workbook_alerts.each do |new_alert|
    alert_id          = new_alert.alert_id
    old_alert         = get_alert(alert_id, local_alerts)
    # check old alert against LIVE API
    live_diff = true
    missing = false
    begin
      original_message  = old_alert.message
      old_alert_live    = monitor_client.get_monitor(alert_id)
      live_update_safe  = ! alert_diff(alert_id, [old_alert], [Alert.new(old_alert_live)])
      new_team          = new_alert.new_team
      new_squad         = new_alert.new_squad
      alert_name        = new_alert.name
      new_slack_channel = new_alert.new_slack_channel
      new_pagerduty_service = new_alert.new_pagerduty_service
      # as of nov. 1
      update_slack      = true
      update_pagerduty  = PAGERDUTY
      new_message       = new_alert.message
    rescue DatadogAPIClient::APIError => e
      case e.to_s
      when /HTTP status code: 404/
        puts "#{alert_id}: Unable to find monitor, skipping"
        status = "Alert missing from Datadog"
        missing = true
      else
        puts "#{alert_id}: Unknown failure retrieving alert from Datadog"
        status = "Unknown failure retrieving alert from Datadog: #{e}"
      end
    end
    next if missing
    begin
      if (! live_update_safe) || (original_message != old_alert_live.message)
        puts "#{alert_id}: Live differences detected, needs reprocessing" if DEBUG
        status = "Live differences, needs reprocessing"
      elsif REALLY_UPDATE_DATADOG == true
        # here is where the real update happens
        old_alert_live.message=new_message
        if monitor_client.validate_monitor(old_alert_live.to_body)
          monitor_client.update_monitor(alert_id, old_alert_live.to_body)
          puts "#{alert_id}: Alert successfully updated live" if DEBUG
          status = "Updated successfully"
        else
          puts "#{alert_id}: Alert failed validation, not updating live" if DEBUG
          status = "Failed validation, update not saved"
          binding.pry if (DEBUG && PRY)
        end
        sleep 1
      elsif REALLY_UPDATE_DATADOG == false
        # dry run- validate
        old_alert_live.message=new_message
        if monitor_client.validate_monitor(old_alert_live.to_body)
          puts "#{alert_id}: Validated successfully, not saving changes due to dry run mode, dry run" if DEBUG
          status = "Validated successfully in dry run mode"
        else
          puts "#{alert_id}: Alert failed validation in dry run mode" if DEBUG
          status = "Failed validation in dry run mode"
          binding.pry if (DEBUG && PRY)
        end
        sleep 1
      end
    rescue Interrupt, Errno::EPIPE
      puts "Hit control-c or broke pipe, adding status to spreadsheet and safely stopping"
      break
      raise Interrupt
    rescue DatadogAPIClient::APIError => e
      if e.to_s =~ /HTTP status code: 404/
        puts "#{alert_id}: Alert not found; skipping"
        status = "Alert not found, potentially deleted"
      else
        puts "#{alert_id}: Unknown API error; skipping"
        status = "Unknown API error: #{e}"
      end
      binding.pry if (DEBUG && PRY)
    ensure
      puts "#{alert_id}: Status updated in workbook" if DEBUG
      output_sheet.row(i).concat [alert_id, status, new_team, new_squad, alert_name, new_slack_channel, new_pagerduty_service, update_slack, update_pagerduty, original_message, new_message]
      i = i+1
    end
  end
end

begin
  puts "Attempting Datadog updates- control-c is safe to use"
  monitor_client = DatadogAPIClient::V1::MonitorsAPI.new
  attempt_datadog_updates(workbook_alerts, local_alerts, report_workbook, monitor_client)
  puts "Work done, writing report to #{report_workbook_file}"
ensure
  report_workbook.write(report_workbook_file)
  puts "Status written, work done"
end

exit
