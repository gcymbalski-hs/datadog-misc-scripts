require 'json'
require 'uri'

DEBUG             = ENV['DEBUG'] == true
SLACK_REGEXP      = /(@slack(?:-[[:word:]]*)*)/
PAGERDUTY_REGEXP  = /(@pagerduty(?:-[[:word:]]*)*)/

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
  attr_reader :new_pagerduty_service

  def initialize(alert_source, original_alert=nil)
    if alert_source.class == String
      alert_object = JSON.parse(alert_source)
      @alert_id = alert_object['id']
      @name     = alert_object['name'].nil? ? '' : alert_object['name']
      @tags     = alert_object['tags']
      @message  = alert_object['message']
      @query    = alert_object['query']
      @alerts   = parse_slack_channels
      @pages    = parse_pagerduty_services
    elsif alert_source.class == RubyXL::Row
      alert_object = alert_source
      @alert_id     = Integer(alert_object[0].value)
      @raw_new_owner = alert_object[1].nil? ? nil : alert_object[1].value
      @product_area = alert_object[2].nil? ? nil : alert_object[2].value
      if original_alert.nil?
        puts "#{@alert_id}: Must pass in original alert (i.e. the real source of truth for everything)" if DEBUG
      end
      @name         = original_alert.name
      @tags         = original_alert.tags
      @message      = original_alert.message
      @query        = original_alert.query
      @alerts       = parse_slack_channels
      @pages        = parse_pagerduty_services
      find_new_owner
      case @new_team
      when 'delete'
        puts "#{alert_id}: Marked for deletion, not finding new slack mapping"
      when 'spark-engagement'
        # specifically do not touch slack channels for campaign-related monitors from Spark
        if ! (@name =~ /campaign/)
          find_new_slack_channel
        end
      else
        find_new_slack_channel
      end
      case @new_team
      when 'delete'
        puts "#{alert_id}: Marked for deletion, not finding new PD service"
      else
        find_new_pagerduty_service if (PAGERDUTY == true)
      end
    elsif alert_source.class == DatadogAPIClient::V1::Monitor
      alert_object  = alert_source
      @alert_id     = alert_source.id
      @name         = alert_source.name
      @tags         = alert_object.tags
      @message      = alert_object.message
      @query        = alert_object.query
      @alerts       = parse_slack_channels
      @pages        = parse_pagerduty_services
    elsif alert_source.class == DatadogAPIClient::V1::SyntheticsTestDetails
      alert_object  = alert_source
      @alert_id     = alert_source.public_id
      @name         = alert_source.name
      @tags         = alert_object.tags
      @message      = alert_object.message
      @query        = "Synthetic - #{alert_source.type} - #{alert_source.subtype}"
      @alerts       = parse_slack_channels
      @pages        = parse_pagerduty_services
    end
  end

  def find_new_owner
    raw_owner = @raw_new_owner
    if raw_owner.nil? && @tags
      # attempt to infer this from team tags if no new owner already specified
      team_tags = @tags.select{|t| t =~ /^team:/}.collect{|t| t.split(':').last}
      squad_tags = @tags.select{|t| t =~ /^squad:/}.collect{|t| t.split(':').last}
      team_tags = team_tags.collect{|t| t.gsub(/_/,'-')}
      squad_tags = squad_tags.collect{|t| t.gsub(/_/,'-')}
      # filter out the 'overloaded' uses of the team tag
      team_tags.reject! do |team|
        team.downcase =~ /university|student|employer/
      end
      if team_tags.count == 0
        puts "#{@alert_id}: No new owner nor team tags, unable to guess" if DEBUG
        nil
      else
        if team_tags.count > 1
          puts "#{@alert_id}: Multiple team tags found, guessing..." if DEBUG
        end
        if team_tags.include?('data')
          team_guess  = 'data'
        end
        if team_tags.include?('platform')
          team_guess  = 'platform-services'
        end
        if team_tags.include?('notifications')
          team_guess  = 'platform-services'
          squad_guess = 'notifications'
        end
        if team_tags.include?('devx')
          team_guess  = 'infrastructure'
          squad_guess = 'devx'
        end
        if team_tags.include?('iam')
          team_guess  = 'platform-services'
          squad_guess = 'access-and-admin'
        end
        if team_tags.include?('cloud-engineering')
          team_guess  = 'infrastructure'
          squad_guess = 'cloud-engineering'
        end
        if team_tags.include?('messaging')
          team_guess  = 'spark-engagement'
          squad_guess = 'messaging'
        end
        if team_guess.nil?
          team_guess = team_tags.first
        end
        puts "#{@alert_id}: Guessing team tag #{team_guess}" if DEBUG
        raw_owner = team_guess
        if squad_guess.nil? && squad_tags.first
          squad_guess = squad_tags.first.split(':').last
          puts "#{@alert_id}: Found squad tag #{squad_guess}" if DEBUG
        else
          puts "#{@alert_id}: Guessing squad #{squad_guess}" if DEBUG
        end 
        raw_owner = "#{team_guess} > #{squad_guess}" if squad_guess
      end
    end
    if raw_owner.nil?
      # if we still couldn't find anything, oof
      puts "#{@alert_id}: Unable to find new owner for alert" if DEBUG
      nil
    else
      raw_owner.gsub!(/&/, 'and')
      raw_owner.gsub!(/&/, 'and')
      # filter out the junk
      product_area = @product_area.downcase if @product_area
      raw_team_guess = raw_owner.split('/').first.split('>').first.strip.downcase
      raw_squad_guess = raw_owner.split('/').last.split('>').last.strip.downcase
      if raw_squad_guess == raw_team_guess
        raw_squad_guess = nil
      end
      case raw_owner.downcase
      when 'delete'
        @to_delete  = true
        @new_team   = 'delete'
      when /monolith/
        @new_team   = 'shared-monolith'
        @new_squad  = nil
      when 'data'
        @new_team   = 'data'
        @new_squad  = raw_squad_guess
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
        @new_squad  = case product_area
                      when 'a&i'
                        'analytics and integrations'
                      when /guidance/
                        'guidance'
                      when /skills/
                        'skills'
                      else
                        raw_squad_guess
                      end
      when /^te /
        @new_team   = 'talent-evolution'
        @new_squad  = case product_area
                      when 'a&i'
                        'analytics and integrations'
                      when /guidance/
                        'guidance'
                      when /skills/
                        'skills'
                      else
                        raw_squad_guess
                      end
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
      when /^ce/ || /cloud-engineering/
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
      when /humans/
        @new_team   = 'humans'
        @new_squad  = raw_squad_guess
      else
        @new_team   = raw_team_guess if raw_team_guess
        @new_squad  = raw_squad_guess if raw_squad_guess
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
    proposed_slack_channel = case @new_team
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
          case @new_squad
          when 'channels'
            'incidents-channels'
          when 'basecamp'
            'incidents-core-basecamp'
          else
            puts "#{@alert_id}: Unknown squad passed in for #{@new_team}: #{@new_squad}" if DEBUG
            nil
          end
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
            puts "#{@alert_id}: Unknown squad passed in for #{@new_team}: #{@new_squad}" if DEBUG
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
          puts "#{@alert_id}: Unknown team passed in: #{new_team}" if DEBUG
          binding.pry if PRY
          nil
        end
    if proposed_slack_channel.nil?
      puts "#{@alert_id}: Could not find a new Slack channel for alert" if DEBUG
    end
    @new_slack_channel = "@slack-#{proposed_slack_channel}" if proposed_slack_channel
  end

  # add our new datadog/pagerduty notifications
  def reprocess_alert
    case @alerts.count
    when 0
      puts "#{@alert_id}: Not taking action on Slack mappings due to no previous mapping" if DEBUG
    when 1
      if reprocess_slack_mappings
        puts "#{@alert_id}: Reprocessed message to include both the original and the new Slack mappings" if DEBUG
      else
        puts "#{@alert_id}: Unable to reprocess message to include both the original and the new Slack mappings" if DEBUG
      end
      if PAGERDUTY == true
        if reprocess_pagerduty_mappings
          puts "#{@alert_id}: Reprocessed message to include only the new PagerDuty service" if DEBUG
        else
          puts "#{@alert_id}: Unable to reprocess message to include only the new PagerDuty service" if DEBUG
        end
      end
    else
      puts "#{@alert_id}: Not processing due to multiple Slack channel targets, please reprocess manually" if DEBUG
    end
    reprocess_tags
  end

  def reprocess_slack_mappings
    # do nothing if we don't have a new channel to deal with
    return true unless @new_slack_channel
    if @alerts.include?(@new_slack_channel)
      puts "#{@alert_id}: New alert channel already included, skipping" if DEBUG
      return true
    end
    # this channel is deprecated but lives on in some places- not cleaning that up right now
    without_uk = @alerts.reject{|x| x == '@slack-incidents-uk' }
    if without_uk.count == 1
      # note that *every* alert with multiple slack channel mappings uses a comma to separate them
      #   (except when things are separated by a conditional)
      # a side effect is that we always know that our 'new' slack channel is always the second one
      @original_message = @message
      @message          = @message.sub(/#{without_uk.first}/, "#{without_uk.first},#{@new_slack_channel}")
      # update alert metadata in memory
      @alerts = parse_slack_channels
      true
    elsif without_uk.count > 1
      puts "#{@alert_id}: Not taking action due to invalid count of current channels" if DEBUG
      false
    else
      true
    end
  end

  def reprocess_pagerduty_mappings
    return true unless @new_pagerduty_service
    if @pages.include?(@new_pagerduty_service)
      puts "#{@alert_id}: New pagerduty service already included, skipping" if DEBUG
      return true
    end
    if @pages.count == 1
      first_page = @pages.first
      @original_message = @message
      #we only ever have one unique paging service in alerts, so replace it globally
      @message = @message.gsub(/#{first_page}/, @new_pagerduty_service)
      @pages = parse_pagerduty_services
      true
    elsif @pages.count > 1
      puts "#{@alert_id}: Found multiple Pagerduty mappings, worth investigating manually"
      false
    else
      true
    end
  end

  def reprocess_tags
    # placeholder - not doing this yet!
    true
  end

  def find_new_pagerduty_service
    # let's not change anything yet if this alert currently doesn't page
    return if @pages.empty?
    current_last_pagerduty_service = @pages.last
    proposed_pagerduty_service = case @new_team
        when 'jobs'
          'jobs'
        when 'spark-engagement'
          'Team-SparkEngagement'
        when 'core'
          case @new_squad
          when 'channels'
            'Squad-Channels'
          when 'basecamp'
            'Squad-Basecamp'
          else
            puts "#{@alert_id}: Unknown squad passed in for #{@new_team}: #{@new_squad}" if DEBUG
            nil
          end
        when 'live-connections'
          'Team-LiveConnections'
        when 'humans'
          'Team-Humans'
        when 'talent-evolution'
          case @product_area
          when /edu email events/
            'EmailEvents'
          when /ats/
            'ATSApplication'
          when /importer/
            'ImporterApplication'
          when /talent guidance/
            'TalentGuidance'
          else
            case @new_squad
            when 'analytics-and-integrations'
              'Squad-AnalyticsandIntegrations'
            when 'talent-guidance'
              'TalentGuidance'
            when 'skills'
              'Skills'
            else
              puts "#{@alert_id}: Unknown squad passed in for #{@new_team}: #{@new_squad}" if DEBUG
              nil
            end
          end
        when 'platform-services'
          'Team-PlatformServices'
        when 'infrastructure'
          case @new_squad
          when 'cloud-engineering'
            'CloudEngineering'
          when 'devx'
            'DevelopmentEnvironmentRDE'
          when 'search-technologies'
            'Squad-SearchTechnologies'
          else
            puts "#{@alert_id}: Unknown squad passed in for #{@new_team}: #{@new_squad}" if DEBUG
            nil
          end
        when 'data'
          case @new_squad
          when 'engineering'
            'Squad-DataEngineering'
          when 'relevance'
            'Squad-DataRelevance'
          else
            puts "#{@alert_id}: Unknown squad passed in for #{@new_team}: #{@new_squad}" if DEBUG
            puts "#{@alert_id}: Falling back to default for team" if DEBUG
            'AirflowandDataPipelines'
          end
        else
          puts "#{@alert_id}: Unknown team passed in: #{new_team}" if DEBUG
          binding.pry if PRY
          nil
        end
    if proposed_pagerduty_service.nil?
      puts "#{@alert_id}: Could not find a new Pagerduty service for alert" if DEBUG
      false
    end
    @new_pagerduty_service = "@pagerduty-#{proposed_pagerduty_service}" if proposed_pagerduty_service
  end

  def parse_slack_channels
    channels = @message.scan(SLACK_REGEXP).flatten
    if channels.uniq.count != channels.count
      puts "#{@alert_id}: WARNING: Duplicate slack channel mappings found" if DEBUG
    end
    channels.uniq
  end

  def parse_pagerduty_services
    pages = @message.scan(PAGERDUTY_REGEXP).flatten
    if pages.uniq.count != pages.count
      puts "#{@alert_id}: WARNING: Duplicate pagerduty service mappings found" if DEBUG
    end
    pages.uniq
  end

  def runbooks()
    URI.extract(@message).filter{|u| u =~ /^http/}.collect{|u| u.gsub(/\)/, '')}.uniq.join("\n")
  end

  def terraform?
    if @tags.any?{|tag| tag == 'terraform:true'}
      true
    else
      if @tags.any?{|tag| tag =~ /repo:terraform/ }
        puts "#{@alert_id}: Found terraform repo tag #{@tags.select{|tag| tag =~/repo:terraform/}.first} but not 'terraform:true', assuming terraform" if DEBUG
        true
      else
        false
      end
    end
  end

  def alerts_in_conditionals?
    # check to see if our alerting channels are completely outside weird conditionals (safe to auto-change)
    # - completely ignore the '@slack-incidents-uk' string
    cleaned_message = @message.gsub(/@slack-incidents-uk/,'')
    if @alerts.reject{|a| a == '@slack-incidents-uk'}.count > 0
      cleaned_message.index(SLACK_REGEXP) < last_conditional_end_index
    else
      false
    end
  end

  def pages_in_conditionals?
    # check to see if our paging channels are completely outside weird conditionals (safe to auto-change)
    # - completely ignore the '@slack-incidents-uk' string
    cleaned_message = @message.gsub(/@slack-incidents-uk/,'')
    if @pages.count > 0
      @message.index(PAGERDUTY_REGEXP) < last_conditional_end_index
    else
      false
    end
  end

  def last_conditional_end_index
    # - completely ignore the '@slack-incidents-uk' string
    cleaned_message = @message.gsub(/@slack-incidents-uk/,'')
    i = 0
    while next_index = cleaned_message.index(/}}/,i)
      i = next_index + 1
    end
    i
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

def get_alert_from_workbook(alert_id, workbook, original_alert=nil)
  puts "#{alert_id}: Finding alert in workbook" if DEBUG
  categories = %w{Employer University Student Platform Identity Cloud-Engineering DevX Messaging Stragglers}
  target_row = nil
  categories.each do |category|
    sheet = workbook[category]
    rows = sheet.select do |row| 
      if ! (row[0].nil? || row[0].value.nil?)
        row[0].value != 'Datadog Alert ID' && Integer(row[0].value) == alert_id
      end
    end
    if rows.empty?
      nil
    else
      puts "#{alert_id}: Found alert in category #{category}" if DEBUG
      target_row = rows.first
      break
    end
  end
  if target_row.nil?
    puts "#{alert_id}: Did not find a match for alert in any worksheet" if DEBUG
    return nil
  else
    return Alert.new(target_row, original_alert)
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
    puts "#{alert_id}: No matching alert found in workbook- probably deleted intentionally" if DEBUG
    return nil
  end

  diff = false
  if json_alert.name != workbook_alert.name
    diff = true
  end
  if json_alert.message != workbook_alert.message
    diff = true
  end
  if json_alert.tags != workbook_alert.tags
    diff = true
  end
  if json_alert.query != workbook_alert.query
    diff = true
  end
  if json_alert.alerts != workbook_alert.alerts
    diff = true
  end
  if json_alert.pages != workbook_alert.pages
    diff = true
  end
  if diff && DEBUG
    puts "#{alert_id}: Differences found between original and new alert configuration!" 
    pp json_alert
    pp workbook_alert
  end
  return diff
end

def get_all_alert_diffs(json_alerts, workbook_alerts)
  json_alerts.select do |alert|
    alert_diff(alert.alert_id, json_alerts, workbook_alerts)
  end
end

def get_missing_alerts(json_alerts, workbook_alerts)
  json_alert_ids = json_alerts.collect{|alert| alert.alert_id}
  workbook_alert_ids = workbook_alerts.collect{|alert| alert.alert_id}
  return json_alert_ids - workbook_alert_ids
end
