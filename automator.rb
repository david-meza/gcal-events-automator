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
require 'redis'


class Automator

  APPLICATION_NAME = 'Special Events Automator'
  CLIENT_SECRETS_PATH = 'client_secret.json'
  # CREDENTIALS_PATH = File.join(Dir.home, '.credentials', "calendar_special_events_credentials.json")
  CREDENTIALS_PATH = 'calendar_special_events_credentials.json'
  DB_PATH = 'database_events.json'
  TEMP_DB_PATH = "temp.json"
  SCOPE = 'https://www.googleapis.com/auth/calendar'

  def initialize
    init_calendar_api
    init_redis
    @raw_events = get_events
    store(@raw_events.to_json, TEMP_DB_PATH)
    update_calendar
    remove_temp_file
    list_calendar_events
    # delete_calendar_events(all_events)
  end

  
  private


  def init_calendar_api
    @client = Google::APIClient.new(:application_name => APPLICATION_NAME)
    @client.authorization = authorize
    @calendar_api = @client.discovered_api('calendar', 'v3')
  end

  def init_redis
    @redis = Redis.new
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

  def remove_temp_file
    FileUtils.remove_file(TEMP_DB_PATH, true)
  end

  def get_differences
    store({'features': []}.to_json) if !File.exists?(DB_PATH) || File.zero?(DB_PATH)

    old_events = JSON.parse(File.read(DB_PATH))['features']
    new_events = JSON.parse(File.read(TEMP_DB_PATH))['features']

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
      # Remove this event so we know that anything that's left in the end was deleted
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
    puts "Found #{differences[:new_events].length} new events, #{differences[:changed_events].length} events modified, and #{differences[:deleted_events].length} deleted events since last check".green
    handle_changes(differences)

    store(@raw_events.to_json)    
  end

  def handle_changes(diff)
    make_new_events(diff[:new_events]) unless diff[:new_events].empty?
    change_existing_events(diff[:changed_events]) unless diff[:changed_events].empty?
    erase_events(diff[:deleted_events]) unless diff[:deleted_events].empty?
  end

  def make_new_events(new_evs)
    new_events = extract_events_data(new_evs)
    create_calendar_events(new_events)
  end

  def change_existing_events(changed_evs)
    changed_events = find_events(changed_evs)
    update_events(changed_events)
  end

  def erase_events(del_evs)
    deleted_events = find_events(del_evs)
    delete_calendar_events(deleted_events)
  end

  def extract_events_data(events_arr)
    filtered_events = []
    events_arr.each do |event|

      next if event['attributes']['EVENT_STARTDATE'].nil? || event['attributes']['EVENT_ENDDATE'].nil?

      description = (event['attributes']['COMMENTS']      ? (event['attributes']['COMMENTS'] + "\n")                      : "") +
                    (event['attributes']['EVENT_CONTACT'] ? ("Contact: "  + event['attributes']['EVENT_CONTACT']) + "\n"  : "") +
                    (event['attributes']['PHONE']         ? ("Phone: "    + event['attributes']['PHONE']) + "\n"          : "") +
                    (event['attributes']['EMAIL']         ? ("Email: "    + event['attributes']['EMAIL']) + "\n"          : "")

      filtered_events << {
        'summary' => event['attributes']['EVENT_NAME'],
        # 'location' => '800 Howard St., San Francisco, CA 94103',
        'description' => description,
        'status' => (event['attributes']['STATUS'] ? (["Confirmed", "Cancelled", "Tentative"].include?(event['attributes']['STATUS']) ? event['attributes']['STATUS'].downcase : "confirmed") : "tentative"),
        'start' => {
          'dateTime' => Time.at(event['attributes']['EVENT_STARTDATE'] / 1000).to_datetime.rfc3339,
          'timeZone' => 'America/New_York',
        },
        'end' => {
          'dateTime' => Time.at(event['attributes']['EVENT_ENDDATE'] / 1000).to_datetime.rfc3339,
          'timeZone' => 'America/New_York',
        }
      }
    end
    filtered_events
  end

  def get_events
    response_body = HTTP.headers(:accept => "application/json").get('https://maps.raleighnc.gov/arcgis/rest/services/SpecialEvents/SpecialEventsView/MapServer/0/query?where=1=1&outFields=OBJECTID,EVENT_NAME,EVENT_STARTDATE,EVENT_ENDDATE,SETUP_STARTTIME,BREAKDOWN_ENDTIME,EVENT_TYPE,STATUS,COMMENTS,EVENT_CONTACT,PHONE,EMAIL&returnGeometry=false&f=json').to_s
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
        :calendarId => 's97r7oev8povdf65o3hmftd0to@group.calendar.google.com',
      },
      :body_object => event )

    puts response.data
  end

  def list_calendar_events(limit = 250)
    # Fetch the next n(10) events for the user
    results = @client.execute(
      :api_method => @calendar_api.events.list,
      :parameters => {
        :calendarId => 's97r7oev8povdf65o3hmftd0to@group.calendar.google.com',
        :maxResults => limit,
        :singleEvents => true,
        :orderBy => 'startTime',
        :timeMin => Time.now.iso8601 })

    puts "Upcoming events:".blue
    puts "No upcoming events found".yellow if results.data.items.empty?
    results.data.items.each do |event|
      start = event.start.date || event.start.date_time
      puts "- #{event.summary} (#{start.strftime("%B %d, %Y")})".magenta
      puts event.id
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
    binding.pry
    event_objects
  end

  def find_event(text)
    results = @client.execute(
      :api_method => @calendar_api.events.list,
      :parameters => {
        :calendarId => 's97r7oev8povdf65o3hmftd0to@group.calendar.google.com',
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
        :calendarId => 's97r7oev8povdf65o3hmftd0to@group.calendar.google.com',
        :eventId => event.id },
      :body_object => event,
      :headers => {'Content-Type' => 'application/json'})
    puts result.data.updated
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
        :calendarId => 's97r7oev8povdf65o3hmftd0to@group.calendar.google.com',
        :eventId => event.id })
    puts result
  end

end


Automator.new

