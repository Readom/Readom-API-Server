#!/usr/bin/env ruby
# encoding: utf-8

require 'rubygems'
require 'bundler'
Bundler.require

require 'json'

class ReadomAPIServer < Sinatra::Base

  enable :sessions

  configure {
    set :server, :puma
  }

  helpers do
    include Rack::Utils
    alias_method :h, :escape_html
  end

  get '/:ext?' do |ext|
    case ext
      when 'json'
        content_type 'application/json'
        '{"status":"OK", "info":"Readom API Server"}'
      else
        content_type 'text/plain'
        'Readom API Server'
    end
  end

  get "/news/v0/:board.:ext" do |board, ext|
    base_uri = 'https://hacker-news.firebaseio.com/v0/'
    firebase = Firebase::Client.new(base_uri)
    list = firebase.get(board).body

    case ext
      when 'json'
        content_type 'application/json'
        list.to_json
      else
        content_type 'text/plain'
        list.join ','
    end
  end

  get '/news/v0/item/:item_id.:ext' do |item_id, ext|
    base_uri = 'https://hacker-news.firebaseio.com/v0/item/'
    firebase = Firebase::Client.new(base_uri)
    item = firebase.get('%s' % item_id).body

    case ext
      when 'json'
        content_type 'application/json'
        item.to_json
      else
        content_type 'text/plain'
        item.to_json
    end
  end
end
