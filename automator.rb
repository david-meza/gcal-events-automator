require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'fileutils'
require 'pry'
require 'http'
require 'json'


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
    raw_events = get_events
    store(raw_events.to_json, TEMP_DB_PATH)
    update_calendar(raw_events)
  end

  
  private


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

  def update_calendar(raw_events)
    return puts "Calendar already up to date!" if FileUtils.compare_file(DB_PATH, TEMP_DB_PATH)

    events = extract_events_data(raw_events)
    # create_calendar_events(events)
    store(raw_events.to_json)
    binding.pry
    FileUtils.remove_file(TEMP_DB_PATH, true)
  end

  def extract_events_data(events_json)
    filtered_events = []
    events_json['features'].each do |event|

      next if event['attributes']['EVENT_STARTDATE'].nil? || event['attributes']['EVENT_ENDDATE'].nil?

      description = (event['attributes']['COMMENTS']      ? (event['attributes']['COMMENTS'] + "\n")                      : "") +
                    (event['attributes']['EVENT_CONTACT'] ? ("Contact: "  + event['attributes']['EVENT_CONTACT']) + "\n"  : "") +
                    (event['attributes']['PHONE']         ? ("Phone: "    + event['attributes']['PHONE']) + "\n"          : "") +
                    (event['attributes']['EMAIL']         ? ("Email: "    + event['attributes']['EMAIL']) + "\n"          : "")

      filtered_events << {
        'summary' => event['attributes']['EVENT_NAME'],
        # 'location' => '800 Howard St., San Francisco, CA 94103',
        'description' => description,
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
    response_body = HTTP.headers(:accept => "application/json").get('https://maps.raleighnc.gov/arcgis/rest/services/SpecialEvents/SpecialEventsView/MapServer/0/query?where=1=1&outFields=EVENT_NAME,EVENT_STARTDATE,EVENT_ENDDATE,SETUP_STARTTIME,BREAKDOWN_ENDTIME,EVENT_TYPE,STATUS,COMMENTS,EVENT_CONTACT,PHONE,EMAIL&returnGeometry=false&f=json').to_s
    JSON.parse(response_body)
  end


  def create_calendar_events(events)
    events.each do |event|
      # Insert new events
      response = @client.execute!(
        :api_method => @calendar_api.events.insert,
        :parameters => {
          :calendarId => 's97r7oev8povdf65o3hmftd0to@group.calendar.google.com',
        },
        :body_object => event )
      puts response
      sleep(0.1) # Wait before req the api again
    end
  end

end


Automator.new

