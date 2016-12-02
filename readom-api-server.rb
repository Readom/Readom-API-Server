#!/usr/bin/env ruby
# encoding: utf-8

require 'rubygems'
require 'bundler'
Bundler.require

require 'json'

# === DataMapper Setup === #
DataMapper.setup(:default, ENV['DATABASE_URL'] || 'sqlite::memory:')
DataMapper::Model.raise_on_save_failure = true
DataMapper::Property::String.length(255)
#DataMapper::Logger.new($stdout, :debug)

class Item
  include DataMapper::Resource
  default_scope(:default).update(:order => [:id.asc])

  property :id, Serial
  property :title, String
  property :url, String
  property :by, String
  property :score, Integer
  property :time, DateTime

  property :created_at, DateTime
  property :updated_at, DateTime
  property :deleted_at, ParanoidDateTime
  property :deleted, ParanoidBoolean, :default => false

  before :update, :log_before_update
  after :save, :log_after_save

  def to_json(json_opts=nil)
    {:id => id, :title => title, :url => url, :by => by, :score => score, :time => time.to_time.to_i}.to_json(json_opts)
  end

  def log_before_update
    puts 'Before update id: %s, title: %s' % [id, title]
    true
  end

  def log_after_save
    puts 'After save id: %s, title: %s' % [id, title]
    true
  end

  class <<self
    alias :original_get :get

    def get_or_fetch(id)
      if item = Item.original_get(id) and item.title
        item
      else
        base_uri = 'https://hacker-news.firebaseio.com/v0/item/'
        firebase = Firebase::Client.new(base_uri)
        f_item = firebase.get(id).body

        if f_item['title']
          item = Item.create(:id => f_item['id']) unless item
          item.update :score => f_item['score'], :time => Time.at(f_item['time']), :title => f_item['title'], :url => f_item['url'], :by => f_item['by']

          item
        else
          nil
        end
      end
    end

    alias :get :get_or_fetch
  end
end

DataMapper.finalize
DataMapper.auto_upgrade!
# === end DataMapper === #

class CounterStore
  # store struct
  # - counter_dates: set : 20161201, 20121202
  # - counter_keys: set : pv, uv
  # - counters: hash : date_pv => 110, date_uv => 10
  # - counter_data: hll(pfadd/pfcount) : date_uv
  # UV key:
  # - IP?
  # - Device?
  # - User(Cookie)
  #    Server: get['Cookie_UV'] ? inc counter : (set-cookie[uv] & inc counter)
  #    Client: response['Cookie_UV'] ? 'save to default[uv]' : ""; request["Cookie_UV"] = default[uv]

  def initialize(url=ENV["REDIS_URL"])
    @url = url

    init_connection
  end

  def push(*arg)
    # arg: uvid, page
    ping

    uvid, page = arg

    t = Time.now.utc
    ts = t.strftime('%F')
    @redis.sadd 'CS:page_list', page

    ['_ALL', page].each do |pg|
      @redis.sadd 'CS:date_list:%s' % pg, ts
      @redis.hincrby 'CS:pv:%s' % pg, ts, 1
      @redis.hincrby 'CS:uv:%s' % pg, ts, 1 if @redis.pfadd 'CS:uv_hll:%s:%s' % [pg, ts], uvid # pfcount 'CS:uv_hll:%s:%s' % [pg, ts]
    end
  end

  def ping(ttl=3)
    begin
      @redis.ping
    rescue => e
      init_connection(ttl)
    end
  end

  def init_connection(ttl=3)
    begin
      @redis = Redis.new(url: @url)
      @redis.sadd 'CS:page_list', '_ALL'
      ping(ttl-1)
    rescue => e
      if ttl > 0
        sleep rand 5
        init_connection(ttl-1)
      end
    end
  end

  def report
    ping

    page_list = @redis.smembers 'CS:page_list'
    stat = page_list.sort.map do |pg|
      date_list = @redis.smembers 'CS:date_list:%s' %pg
      s = date_list.map do |dt|
        pv = @redis.hget 'CS:pv:%s' % pg, dt

        uv = @redis.pfcount 'CS:uv_hll:%s:%s' % [pg, dt]
        _uv = @redis.hget('CS:uv:%s' % pg, dt).to_i
        puts 'page: %s, date: %s, uv_hll: %d, uv: %d' % [pg, dt, uv, _uv] if uv != _uv
        @redis.hincrby 'CS:uv:%s' % pg, dt, (uv - _uv) if uv > _uv
        #@redis.hset 'CS_uv', dt, uv

        [[:DATE, :PV, :UV], [dt, pv, uv]].transpose.to_h
      end.sort {|x,y| x[:DATE] <=> y[:DATE]}

      [pg, s]
    end.to_h
  end
end

$info = "Readom API Server"
$time = Time.now.strftime('%FT%T%:z')
$counter = CounterStore.new

class ReadomAPIServer < Sinatra::Base

  enable :sessions

  configure {
    set :server, :puma
  }

  helpers do
    def counter_push(page)
      @uvid = request['R-UVID'] || request.cookies['R-UVID'] || request.env['HTTP_R_UVID'] || ''

      $counter.push @uvid, page
    end
  end

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  end

  get "/news/v0/:board.:ext" do |board, ext|
    counter_push board

    base_uri = 'https://hacker-news.firebaseio.com/v0/'
    firebase = Firebase::Client.new(base_uri)
    list = firebase.get(board).body
    if limit = params['limit'] and max = limit.to_i - 1
      list = list.shuffle[0..max]
    end

    case ext
      when 'json'
        content_type 'application/json'
        list.map{|item_id| Item.get(item_id)}.to_json
      else
        content_type 'text/plain'
        list.join ','
    end
  end

  get '/news/v0/item/:item_id.:ext' do |item_id, ext|
    counter_push :item

    if item = Item.get(item_id)
      puts 'hit id %d' % [item_id]
    else
      puts 'miss id %d' % [item_id]
      item = {}
    end

    case ext
      when 'json'
        content_type 'application/json'
        item.to_json
      else
        content_type 'text/plain'
        item.to_json
    end
  end

  get '/report.:ext' do |ext|
    counter_push :report

    case ext
      when 'json'
        content_type 'application/json'
        $counter.report.to_json
      else
        content_type 'text/plain'
        $counter.report.to_yaml
    end
  end

  get '/uvid.:ext' do |ext|
    counter_push :uvid

    case ext
      when 'json'
        content_type 'application/json'
        {:UVID => @uvid}.to_json
      else
        content_type 'text/plain'
        'UVID: %s' % @uvid
    end
  end

  get '/:ext?' do |ext|
    counter_push :_OTHERS
    case ext
      when 'json'
        content_type 'application/json'
        '{"status":"OK", "info":"%s", "time":"%s"}' % [$info, $time]
      else
        content_type 'text/plain'
        'status: OK; info: %s; time: %s' % [$info, $time]
    end
  end
end
