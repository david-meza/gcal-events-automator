require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'fileutils'
require 'pry'
require 'http'
require 'colorize'
require 'json'
require 'dotenv'


class Automator

  APPLICATION_NAME = 'Special Events Automator'
  CLIENT_SECRETS_PATH = File.join(Dir.home, '.credentials', 'client_secret.json')
  CREDENTIALS_PATH = File.join(Dir.home, '.credentials', "calendar_special_events_credentials.json")
  DB_PATH = File.join(Dir.home, '.tmp', 'database_events.json')
  TEMP_DB_PATH = File.join(Dir.home, '.tmp', "temp.json")
  SCOPE = 'https://www.googleapis.com/auth/calendar'

  def initialize
    create_directories
    init_calendar_api
    @raw_events = get_events
    @gis_token = authorize_arcgis
  end

  def check_event_updates
    store(@raw_events.to_json, TEMP_DB_PATH)
    update_calendar
    remove_file(TEMP_DB_PATH)
    list_calendar_events(2)
    puts @e ? "Finished running script with the following exception: #{@e}".red : "Finished running script with no errors".green

    # Uncomment when you need to delete everything that's on Google Calendar
    # all_events = list_calendar_events
    # delete_calendar_events(all_events)
    # remove_file(DB_PATH)
  end

  
  private

  def create_directories
    FileUtils.mkdir_p(File.join(Dir.home, '.credentials'))
    FileUtils.mkdir_p(File.join(Dir.home, '.tmp'))
    FileUtils.touch(DB_PATH, { verbose: true })
  end

  #Sample Event
  # {"attributes":
  #   { "OBJECTID":30,
  #     "EVENT_NAME":"Charity Dodgeball Tournament",
  #     "EVENT_STARTDATE":1444968000000,
  #     "EVENT_ENDDATE":1444968000000,
  #     "SETUP_STARTTIME":"12p",
  #     "BREAKDOWN_ENDTIME":"9p",
  #     "EVENT_TYPE":"General Event",
  #     "STATUS":"Cancelled",
  #     "COMMENTS":null,
  #     "EVENT_CONTACT":"Allen Cobb",
  #     "PHONE":"9104097467",
  #     "EMAIL":"allencobb@gmail.com"
  #   }
  # }


  def init_calendar_api
    @client = Google::APIClient.new(:application_name => APPLICATION_NAME)
    @client.authorization = authorize
    @calendar_api = @client.discovered_api('calendar', 'v3')
  end


  def authorize
    FileUtils.mkdir_p(File.dirname(CREDENTIALS_PATH))

    file_store = Google::APIClient::FileStore.new(CREDENTIALS_PATH)
    storage = Google::APIClient::Storage.new(file_store)
    auth = storage.authorize

    if auth.nil? || (auth.expired? && auth.refresh_token.nil?)
      app_info = Google::APIClient::ClientSecrets.load(CLIENT_SECRETS_PATH)
      flow = Google::APIClient::InstalledAppFlow.new({
        :client_id => app_info.client_id,
        :client_secret => app_info.client_secret,
        :scope => SCOPE})
      auth = flow.authorize(storage)
      puts "Credentials saved to #{CREDENTIALS_PATH}" unless auth.nil?
    end
    auth
  end

  def store(content, path = DB_PATH)    
    file = File.open(path, "w")
    file.write(content)
    file.close
  end

  def remove_file(path = TEMP_DB_PATH)
    FileUtils.remove_file(path, true)
  end

  def get_differences
    store({'features': []}.to_json) if !File.exists?(DB_PATH) || File.zero?(DB_PATH)

    begin
      old_events = JSON.parse(File.read(DB_PATH))['features']
      new_events = JSON.parse(File.read(TEMP_DB_PATH))['features']
    rescue => @e
      puts "Exception ocurred: #{@e}"
      old_events = []
      new_events = []
    end

    old_events_hash = {}
    # Make a map for faster indexing
    old_events.each do |event|
      old_events_hash[event['attributes']['OBJECTID']] = event
    end

    freshly_inserted_events = []
    changed_events = []

    new_events.each do |event|
      # Detect an event freshly inserted since last check
      if old_events_hash[event['attributes']['OBJECTID']].nil?
        freshly_inserted_events << event
      # Detect if the event has been modified 
      elsif event != old_events_hash[event['attributes']['OBJECTID']]
        changed_events << event
      # Else both events are the same and we don't need to do anything
      end
      # Remove this event so we know that any events that are left in the end are deleted
      old_events_hash.delete(event['attributes']['OBJECTID'])

    end

    {
      new_events: freshly_inserted_events,
      changed_events: changed_events,
      deleted_events: old_events_hash.values
    }

  end

  def update_calendar
    return puts "**********************\nCalendar already up to date!\n**********************".green if FileUtils.compare_file(DB_PATH, TEMP_DB_PATH)

    # Find any differences between the old events db and the most recent one
    differences = get_differences
    puts "*****************************\nFound #{differences[:new_events].length} new events, #{differences[:changed_events].length} events modified, and #{differences[:deleted_events].length} deleted events since last check\n*****************************".green

    handle_changes(differences)

    # Store the most recent version of the arcgis db locally (with possible GoogleID additions)
    store(get_events.to_json)    
  end

  def authorize_arcgis
    response_body = HTTP.post('https://maps.raleighnc.gov/arcgis/tokens/', :form => { :username => ENV['ARCGIS_USERNAME'], :password => ENV['ARCGIS_PASSWORD'], :f => 'json'}).body.to_s
    puts "Temporary arcgis auth token (expires in 1 hour):"
    p JSON.parse(response_body)['token']
  end

  def handle_changes(diff)
    make_new_events(diff[:new_events]) unless diff[:new_events].empty?
    change_existing_events(diff[:changed_events]) unless diff[:changed_events].empty?
    erase_events(diff[:deleted_events]) unless diff[:deleted_events].empty?
  end

  def make_new_events(new_evs)
    processed_new_events = extract_events_data(new_evs)
    create_calendar_events(processed_new_events)
  end

  def change_existing_events(changed_evs)
    processed_changed_events = extract_events_data(changed_evs)
    update_events(processed_changed_events)
  end

  def erase_events(del_evs)
    processed_deleted_events = extract_events_data(del_evs)
    delete_calendar_events(processed_deleted_events)
  end

  def extract_events_data(events_arr)
    filtered_events = []
    events_arr.each do |event|

      next if event['attributes']['EVENT_STARTDATE'].nil? || event['attributes']['EVENT_ENDDATE'].nil?

      description = (event['attributes']['COMMENTS']      ? (               event['attributes']['COMMENTS'] + "\n\n")       : "") +
                    (event['attributes']['EVENT_CONTACT'] ? ("Contact: "  + event['attributes']['EVENT_CONTACT']) + "\n"  : "") +
                    (event['attributes']['PHONE']         ? ("Phone: "    + event['attributes']['PHONE']) + "\n"          : "") +
                    (event['attributes']['EMAIL']         ? ("Email: "    + event['attributes']['EMAIL']) + "\n"          : "")

      start_time = event['attributes']['SETUP_STARTTIME'] ? parse_time_to_seconds(event['attributes']['SETUP_STARTTIME'])   : 0
      end_time = event['attributes']['BREAKDOWN_ENDTIME'] ? parse_time_to_seconds(event['attributes']['BREAKDOWN_ENDTIME']) : 0

      filtered_events << {
        'summary' => event['attributes']['EVENT_NAME'],
        # 'location' => '800 Howard St., San Francisco, CA 94103',
        'description' => description,
        'OBJECTID' => event['attributes']['OBJECTID'],
        'GOOGLEID' => event['attributes']['GOOGLEID'],
        'status' => (event['attributes']['STATUS'] ? (["Confirmed", "Cancelled", "Tentative"].include?(event['attributes']['STATUS']) ? event['attributes']['STATUS'].downcase : "confirmed") : "tentative"),
        'start' => {
          'dateTime' => Time.at( (event['attributes']['EVENT_STARTDATE'] / 1000) + start_time).to_datetime.rfc3339,
          'timeZone' => 'America/New_York',
        },
        'end' => {
          'dateTime' => Time.at( (event['attributes']['EVENT_ENDDATE'] / 1000) + end_time).to_datetime.rfc3339,
          'timeZone' => 'America/New_York',
        }
      }
    end
    filtered_events
  end

  def parse_time_to_seconds(standard_time)
    # Matches different formats like "7:00pm" or "07:00PM" or "7:00 pm"
    original, hours, minutes, am_or_pm = standard_time.match( /(\d+):(\d+)\s*(am|pm)/i ).to_a
    return 0 if hours.nil? || minutes.nil? || am_or_pm.nil? # Sorry I didn't get your formatting (e.g. 7pm)
    hours, minutes, am_or_pm = hours.to_i, minutes.to_i, am_or_pm.downcase

    # Normalize hours to 0 if they are 12, so we can easily add the am/pm offset
    hours = 0 if am_or_pm == 'am' && hours == 12 || am_or_pm == 'pm' && hours == 12
    
    # Return parsed time in SECONDS
    hours * 3600 + minutes * 60 + (am_or_pm.downcase == 'am' ? 0 : 43200) 
  end

  def get_events
    response_body = HTTP.headers(:accept => "application/json").get('https://maps.raleighnc.gov/arcgis/rest/services/SpecialEvents/SpecialEventsView/MapServer/0/query?where=1=1&outFields=OBJECTID,GOOGLEID,EVENT_NAME,EVENT_STARTDATE,EVENT_ENDDATE,SETUP_STARTTIME,BREAKDOWN_ENDTIME,EVENT_TYPE,STATUS,COMMENTS,EVENT_CONTACT,PHONE,EMAIL&returnGeometry=false&f=json').to_s
    JSON.parse(response_body)
  end


  def create_calendar_events(events)
    events.each do |event|
      create_calendar_event(event)
      sleep(0.1) # Wait before requesting from the api again
    end
  end

  def create_calendar_event(event)
    # Insert new events
    response = @client.execute(
      :api_method => @calendar_api.events.insert,
      :parameters => {
        :calendarId => ENV['CALENDAR_ID'],
      },
      :body_object => event )

    puts "Created new event #{response.data.summary} with id #{response.data.id}".cyan

    add_googleid(event, response.data)
  end

  def add_googleid(arcgis_event, google_event)
    response = HTTP.post('http://maps.raleighnc.gov/arcgis/rest/services/SpecialEvents/SpecialEvents/FeatureServer/0/updateFeatures', :form => { features: [{"attributes": { "OBJECTID" => arcgis_event['OBJECTID'], "GOOGLEID" => google_event.id } } ].to_json, token: @gis_token, f: 'json' })

    puts "Attempting to add Google ID attribute to the ARCGIS database".blue
    puts response.body.to_s
  end

  def list_calendar_events(limit = 250)
    # Fetch the next n(10) events for the user
    results = @client.execute(
      :api_method => @calendar_api.events.list,
      :parameters => {
        :calendarId => ENV['CALENDAR_ID'],
        :maxResults => limit,
        :singleEvents => true,
        :orderBy => 'startTime',
        :timeMin => Time.now.iso8601 })

    puts "\nUpcoming events (listing first #{limit}):\n".blue
    puts "No upcoming events found".yellow if results.data.items.empty?
    
    results.data.items.each do |event|
      event['GOOGLEID'] = event.id
      start = event.start.date || event.start.date_time
      puts "- #{event.summary} (#{start.strftime("%B %d, %Y")})".magenta
      puts event.htmlLink
      puts "------------------------------"
    end
  end

  def find_events(events)
    event_objects = []
    events.each do |event|
      data = find_event(event['attributes']['EVENT_NAME'])
      puts "Could not find event with name #{event['attributes']['EVENT_NAME']}" if data.nil?
      event_objects << data unless data.nil?
      sleep(0.1) # Wait before requesting from the api again
    end

    event_objects
  end

  def find_event(text)
    results = @client.execute(
      :api_method => @calendar_api.events.list,
      :parameters => {
        :calendarId => ENV['CALENDAR_ID'],
        :maxResults => 1,
        :q => text })

    return (results.data.items.empty? ? nil : results.data.items[0])
  end

  def update_events(events)
    events.each do |event|
      update_event(event)
      sleep(0.1) # Wait before requesting from the api again
    end
  end

  def update_event(event)
    result = @client.execute(
      :api_method => @calendar_api.events.update,
      :parameters => {
        :calendarId => ENV['CALENDAR_ID'],
        :eventId => event['GOOGLEID'] },
      :body_object => event,
      :headers => {'Content-Type' => 'application/json'})
    
    puts "Updated event #{result.data.summary}."
  end

  def delete_calendar_events(events)
    events.each do |event|
      delete_calendar_event(event)
      sleep(0.1) # Wait before requesting from the api again
    end
  end

  def delete_calendar_event(event)
    result = @client.execute(
      :api_method => @calendar_api.events.delete,
      :parameters => {
        :calendarId => ENV['CALENDAR_ID'],
        :eventId => event['GOOGLEID'] || event.id })

    puts "Deleted event #{event['summary'] || event.summary}."
  end

end


Dotenv.load
a = Automator.new
a.check_event_updates

