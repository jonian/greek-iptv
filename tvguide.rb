require 'uri'
require 'json'
require 'ostruct'

require 'faraday'
require 'faraday/retry'

require 'builder'
require 'unaccent'

require 'active_support/all'

ENV['TZ'] = 'Europe/Athens'

module TvGuide
  PGNAME = 'greek-iptv'
  GITURI = 'https://raw.githubusercontent.com/jonian/greek-iptv'

  class Provider
    attr_reader :name, :config

    def initialize
      @name   = self.class.name.demodulize.downcase
      @config = JSON.load(File.read 'tvguide.json')[name]

      raise "Config not found for #{name}!" if config.nil?
    end

    def run
      return [] if mapping.blank?

      matrix.flat_map do |item|
        parse(fetch item).filter_map do |item|
          process(item) if item
        end
      end
    end

    def matrix
      Array(Date.today.yesterday..Date.today.next_week)
    end

    def fetch
      raise NotImplementedError
    end

    def parse(data)
      Array(data)
    end

    def process(item)
      Hash(item)
    end

    private

    def connection
      Faraday.new(config['url'], ssl: { verify: false }) do |conn|
        conn.headers = config['headers']
        conn.request :retry, max: 5, interval: 2, interval_randomness: 0.5
      end
    end

    def request(method, path = nil, body: nil, data: nil, **kwargs)
      resp = connection.send(method, path, **kwargs) do |req|
        req.body = JSON.generate(body) if body
        req.body = URI.encode_www_form(data) if data
      end

      resp.body
    end

    def mapping
      config.fetch('mapping', {})
    end
  end

  class Digea < Provider
    def fetch(date)
      request(:post, data: { action: 'get_events', date: date })
    end

    def parse(data)
      JSON.load(data)
    end

    def process(item)
      chid = item.fetch('channel_id', '0')
      return unless mapping.key?(chid)

      id, name = mapping[chid]

      {
        channel: {
          id: id,
          name: name
        },
        programme: {
          channel: id,
          start: item['actual_time'],
          stop: item['end_time'],
          title: item['title'],
          desc: item['long_synopsis']
        }
      }
    end
  end

  class Cosmote < Provider
    def fetch(date)
      @date = date

      query = {
        id: 'dayprogram_WAR_OTETVportlet',
        lifecycle: '2',
        state: 'normal',
        mode: 'view',
        cacheability: 'cacheLevelPage'
      }

      param = {
        date: date.strftime('%d-%m-%Y'),
        feedType: 'EPG',
        start: '0',
        end: '102',
        platform: 'DTH',
        categoryId: '37155'
      }

      query.transform_keys! { |key| "p_p_#{key}" }
      param.transform_keys! { |key| "_dayprogram_WAR_OTETVportlet_#{key}" }

      request(:get, **query, **param)
    end

    def parse(data)
      JSON.load(data).fetch('channels', []).flat_map do |ch|
        ch.fetch('shows', []).map do |sh|
          sh.merge({'channelId' => ch['ID'] })
        end
      end
    end

    def process(item)
      chid = item.fetch('channelId', '0')
      return unless mapping.key?(chid)

      id, name = mapping[chid]

      stime = item['startTime']
      etime = item['endTime']

      start = @date.strftime("%Y-%m-%d #{stime}:00")
      stop  = @date.strftime("%Y-%m-%d #{etime}:00")

      if start.to_time > stop.to_time
        stop = @date.tomorrow.strftime("%Y-%m-%d #{etime}:00")
      end

      {
        channel: {
          id: id,
          name: name
        },
        programme: {
          channel: id,
          start: start,
          stop: stop,
          title: item['title'],
          desc: item['title']
        }
      }
    end
  end

  class Ertflix < Provider
    def fetch(date)
      data = request(:post, 'v1/EpgTile/FilterProgramTiles', body: {
        platformCodename: 'www',
        from: date.rfc3339,
        to: date.tomorrow.rfc3339,
        orChannelCodenames: mapping.keys
      })

      request(:post, 'v2/Tile/GetTiles', body: {
        platformCodename: 'www',
        requestedTiles: JSON.load(data)
          .fetch('Programs', {})
          .values.flatten
          .map { |item| { id: item['Id'] } }
      })
    end

    def parse(data)
      JSON.load(data).fetch('Tiles', [])
    end

    def process(item)
      chid = item.dig('TileChannel', 'Codename')
      return unless mapping.key?(chid)

      id, name = mapping[chid]

      {
        channel: {
          id: id,
          name: name
        },
        programme: {
          channel: id,
          start: item['Start'],
          stop: item['Stop'],
          title: item['Title'],
          desc: item['Description'] || item['Title']
        }
      }
    end
  end

  class Static < Provider
    def fetch(date)
      @date = date
      config['programme']
    end

    def process(item)
      chid = item['id']
      return unless mapping.key?(chid)

      id, name = mapping[chid]

      stime = item['start']
      etime = item['end']

      start = @date.strftime("%Y-%m-%d #{stime}:00")
      stop  = @date.strftime("%Y-%m-%d #{etime}:00")

      {
        channel: {
          id: id,
          name: name
        },
        programme: {
          channel: id,
          start: start,
          stop: stop,
          title: item['title'],
          desc: item['desc'] || item['title']
        }
      }
    end
  end

  class Builder
    attr_reader :ids

    def initialize
      @ids = JSON.load(File.read 'channels.json').map do |item|
        item['name']
      end
    end

    def run
      xml = ::Builder::XmlMarkup.new(indent: 2)
      xml.instruct! :xml, version: '1.0'
      xml.declare! :DOCTYPE, :tv, :SYSTEM, 'xmltv.dtd'

      xml.tv('generator-info-name' => PGNAME, 'generator-info-url' => GITURI) do
        channels.each do |channel|
          xml.channel **channel.slice(:id) do
            xml.tag! 'display-name', channel[:name], lang: 'el'
          end
        end

        programmes.each do |programme|
          programme[:start] = time programme[:start]
          programme[:stop]  = time programme[:stop]

          xml.programme **programme.slice(:start, :stop, :channel) do
            xml.title programme[:title], lang: 'el'
            xml.desc programme[:desc]
          end
        end
      end

      File.write('tvguide.xml', xml.target!)
    end

    private

    def tvdata
      @tvdata ||= Provider.descendants.flat_map do |provider|
        provider.new.run
      end
    end

    def channels
      @channels ||= tvdata
        .map    { |item| item[:channel] }
        .uniq   { |item| item[:id] }
        .select { |item| ids.include? item[:id] }
    end

    def programmes
      @programmes ||= tvdata
        .map    { |item| item[:programme] }
        .select { |item| ids.include? item[:channel] }
        .map    { |item| item.transform_values!(&:strip) }
    end

    def time(string)
      Time.parse(string).strftime('%Y%m%d%H%M%S %z')
    end
  end

  class << self
    def run
      builder = Builder.new
      builder.run
    end
  end
end
