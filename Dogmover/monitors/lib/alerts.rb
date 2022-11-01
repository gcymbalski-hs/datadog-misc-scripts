require 'json'
require 'uri'

class Alert
  attr_reader :alert_object
  attr_reader :name
  attr_reader :alert_id
  attr_reader :message
  attr_reader :tags
  attr_reader :query
  attr_reader :new_team
  attr_reader :new_squad
  attr_reader :product_area
  attr_reader :alerts
  attr_reader :pages
  attr_reader :channels_consistent
  attr_reader :raw_new_owner
  attr_reader :to_delete
  attr_reader :new_slack_channel

  def initialize(alert_source)
    if alert_source.class == String
      alert_object = JSON.parse(alert_source)
      @alert_id = alert_object['id']
      @name     = alert_object['name'].nil? ? '' : alert_object['name']
      @tags     = alert_object['tags']
      @message  = alert_object['message']
      @query    = alert_object['query']
      @alerts   = parse_slack_channels
      @pages    = parse_pagerduty_service
    elsif alert_source.class == RubyXL::Row
      alert_object = alert_source
      @alert_id     = Integer(alert_object[0].value)
      find_new_owner(alert_object[1].nil? ? nil : alert_object[1].value)
      @product_area = alert_object[2].nil? ? nil : alert_object[2].value
      @name         = alert_object[3].nil? ? nil : alert_object[3].value
      @tags         = (alert_object[6].nil? || \
                       alert_object[6].value.nil? ) ? [] : alert_object[6].value.split("\n")
      @message      = alert_object[12].value
      @query        = alert_object[13].value
      @alerts       = (alert_object[8].nil? || \
                       alert_object[8].value.nil? ) ? [] : alert_object[8].value.split("\n")
      @pages        = (alert_object[9].nil? || \
                       alert_object[9].value.nil?) ? [] : alert_object[9].value.split("\n")
      @channels_consistent = test_consistent_channels
      if @channels_consistent == false
        puts "#{@alert_id}: Found inconsistent alerting channels" if ENV['DEBUG'] == 'true'
      end
      find_new_slack_channel
    end
  end

  def find_new_owner(raw_owner)
    @raw_new_owner = raw_owner 
    if raw_owner.nil?
      nil
    else
      raw_owner.gsub!(/&/, 'and')
      raw_owner.gsub!(/&/, 'and')
      # filter out the junk
      raw_team_guess = raw_owner.split('/').first.split('>').first.strip.downcase
      raw_squad_guess = raw_owner.split('/').last.split('>').last.strip.downcase
      if raw_squad_guess == raw_team_guess
        raw_squad_guess = nil
      end
      case raw_owner.downcase
      when 'delete'
        @to_delete  = true
        @new_team   = 'delete'
      when 'data'
        @new_team   = 'data'
        @new_squad  = nil
      when /^platform/
        @new_team   = 'platform-services'
        @new_squad  = raw_squad_guess
      when /^job/
        @new_team   = 'jobs'
        @new_squad  = raw_owner.split(' ').last.strip.downcase
      when /^core/
        @new_team   = 'core'
        if raw_owner.downcase =~ /\//
          @new_squad  = raw_squad_guess
        else
          @new_squad  = raw_owner.split(' ').last.strip.downcase
        end
      when /integration/
        @new_team   = 'talent-evolution'
        @new_squad  = 'analytics and integrations'
      when /^talent/
        @new_team   = 'talent-evolution'
        @new_squad  = raw_squad_guess
      when /^te/
        @new_team   = 'talent-evolution'
        @new_squad  = raw_squad_guess
      when /^se /
        @new_team   = 'spark-engagement'
        @new_squad  = raw_owner.split(' ').last.strip.downcase
      when /^spark/
        @new_team   = 'spark-engagement'
        @new_squad  = nil
      when 'monetization'
        @new_team   = 'jobs'
        @new_squad  = 'monetization'
      when 'basecamp'
        @new_team   = 'core'
        @new_squad  = 'basecamp'
      when /search/
        @new_team   = 'infrastructure'
        @new_squad  = 'search-technologies'
      when /^ce/
        @new_team   = 'infrastructure'
        @new_squad  = 'cloud-engineering'
      when 'devx'
        @new_team   = 'infrastructure'
        @new_squad  = 'devx'
      when 'ios core'
        @new_team   = 'platform-services'
        @new_squad  = 'mobile'
      when 'mobile'
        @new_team   = 'platform-services'
        @new_squad  = 'mobile'
      when /live connections/
        @new_team   = 'live-connections'
        @new_squad  = nil
      when 'dep'
        @new_team   = 'platform-services'
        @new_squad  = 'domain events'
      when 'live connections'
        @new_team   = 'live-connections'
        @new_squad  = nil
      when /humans/
        @new_team   = 'humans'
        @new_squad  = raw_squad_guess
      else
        nil
      end
      @new_team = @new_team.gsub(/ /, '-') if @new_team
      @new_squad = @new_squad.gsub(/ /, '-') if @new_squad
      @new_squad = @new_squad.gsub(/avocates/, 'advocates') if @new_squad
    end
  end

  def find_new_slack_channel
    # let's not change anything yet if this alert currently doesn't go to slack
    return if @alerts.empty?
    current_last_slack_channel = @alerts.last
    @new_slack_channel = case @new_team
        when 'jobs'
          'incidents-jobs'
        when 'spark-engagement'
          case @new_squad
          when 'messaging'
            'incidents-employer-connections-messaging'
          when 'campaigns'
            'incidents-spk-campaign'
          else
            'incidents-spark-engagement'
          end
        when 'core'
          'errors-core'
        when 'live-connections'
          'incidents-live-cxns'
        when 'humans'
          'incidents-humans'
        when 'talent-evolution'
          case @new_squad
          when 'analytics-and-integrations'
            'incidents-te-analytics-int'
          when 'talent-guidance'
            'incidents-te-talent'
          when 'skills'
            'incidents-te-skills'
          else
            puts "Unknown squad passed in for #{new_team}"
            nil
          end
        when 'platform-services'
          case @new_squad
          when 'notifications'
            'incidents-notifications'
          else
            'incidents-platform-services'
          end
        when 'infrastructure'
          case @new_squad
          when 'cloud-engineering'
            'incidents-cloud-engineering'
          when 'devx'
            'incidents-dev-experience'
          when 'search-technologies'
            'incidents-search-technologies'
          else
            'incidents-infrastructure'
          end
        when 'data'
          'incidents-data'
        else
          puts "Unknown team passed in: #{new_team}"
          nil
        end
  end

  def append_new_slack_channel
    if new_slack_channel = find_new_slack_channel
      @new_message = \
        @message.gsub(/#{current_last_slack_channel}/, "#{current_last_slack_channel} @slack-#{new_slack_channel}")
        @message = @new_message
    end
  end

  def find_new_pagerduty_service
    # let's not change anything yet if this alert currently doesn't page
    return if @pages.empty?
    puts "placeholder"
  end

  def parse_slack_channels
    @message.scan(/(@slack(?:-[[:word:]]*)*)/).flatten.uniq
  end

  def parse_pagerduty_service
    @message.scan(/(@pagerduty(?:-[[:word:]]*)*)/).flatten.uniq
  end

  def test_consistent_channels()
    parse_slack_channels == @alerts && parse_pagerduty_service == @pages
  end

  def runbooks()
    URI.extract(@message).filter{|u| u =~ /^http/}.collect{|u| u.gsub(/\)/, '')}.uniq.join("\n")
  end

  def terraform?
    if @tags.any?{|tag| tag == 'terraform:true'}
      true
    else
      if @tags.any?{|tag| tag =~ /repo:terraform/ }
        puts "#{@alert_id}: Found terraform repo tag #{@tags.select{|tag| tag =~/repo:terraform/}.first} but not 'terraform:true', assuming terraform" if ENV['DEBUG'] == 'true'
        true
      else
        false
      end
    end
  end

  def environments()
    envs = tags.select{|tag| tag =~ /env:/}.collect{|x| x.split(':')[1]}
    if @message =~ /production/i
      envs << 'production'
    end
    if envs.empty?
      'any (potentially)'
    else
      envs.uniq.join("\n")
    end
  end
  
  def teams()
    @tags.select{|tag| tag =~ /team:/}.collect{|x| x.split(':')[1]}.uniq.join("\n")
  end

  def resource_name
    /(resource_name:[\w:]*)/.match(@query).to_a.collect{|x| x.gsub(/resource_name:/, '')}.uniq.join("\n")
  end

  def summarize()
    [@alert_id, @new_owner, @product_area, @name, environments, teams, @tags.join("\n"), runbooks, @alerts.join("\n"), @pages.join("\n"), resource_name, terraform?, @message, @query]
  end
end

def get_alert_from_workbook(alert_id, workbook)
  puts "#{alert_id}: Finding alert in workbook" if ENV['DEBUG'] == 'true'
  categories = %w{Employer University Student Platform Identity Cloud-Engineering DevX Messaging Stragglers}
  target_row = nil
  categories.each do |category|
    sheet = workbook[category]
    rows = sheet.select do |row| 
      if ! row[0].nil?
        row[0].value != 'Datadog Alert ID' && Integer(row[0].value) == alert_id
      end
    end
    if rows.empty?
      nil
    else
      puts "#{alert_id}: Found alert in category #{category}" if ENV['DEBUG'] == 'true'
      target_row = rows.first
      break
    end
  end
  if target_row.nil?
    puts "#{alert_id}: Did not find a match for alert in any worksheet" if ENV['DEBUG'] == 'true'
    return nil
  else
    return Alert.new(target_row)
  end
end

#alerts should be an array of Alert objects
def get_alert(alert_id, alerts)
  alerts.select do |alert|
    alert.alert_id == alert_id
  end.first
end

def alert_diff(alert_id, json_alerts, workbook_alerts)
  json_alert      = get_alert(alert_id, json_alerts)
  workbook_alert  = get_alert(alert_id, workbook_alerts)

  if workbook_alert.nil?
    puts "#{alert_id}: No matching alert found in workbook- probably deleted intentionally" if ENV['DEBUG'] == 'true'
    return nil
  end

  diff = false
  if ! json_alert.name == workbook_alert.name
    diff = true
  end
  if ! json_alert.message == workbook_alert.message
    diff = true
  end
  if ! json_alert.tags == workbook_alert.tags
    diff = true
  end
  if ! json_alert.query == workbook_alert.query
    diff = true
  end
  if ! json_alert.alerts == workbook_alert.alerts
    diff = true
  end
  if ! json_alert.pages == workbook_alert.pages
    diff = true
  end
  if diff
    if ENV['DEBUG'] == 'true'
      puts "#{alert_id}: Differences found between original and new alert configuration!"
      pp json_alert
      pp workbook_alert
    end
    return alert_id
  else
    return nil
  end
end

def get_all_alert_diffs(json_alerts, workbook_alerts)
  json_alerts.collect do |alert|
    alert_diff(alert.alert_id, json_alerts, workbook_alerts)
  end
end

def get_missing_alerts(json_alerts, workbook_alerts)
  json_alert_ids = json_alerts.collect{|alert| alert.alert_id}
  workbook_alert_ids = workbook_alerts.collect{|alert| alert.alert_id}
  return json_alert_ids - workbook_alert_ids
end

