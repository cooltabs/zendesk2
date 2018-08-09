# frozen_string_literal: true
module Zendesk2::Request
  class << self
    alias cistern_included included

    def included(receiver)
      receiver.extend(ClassMethods)
      cistern_included(receiver)
      super
    end
  end

  # provide class-level request information
  module ClassMethods
    def request_method(request_method = nil)
      @request_method ||= request_method
    end

    def request_params(&block)
      @request_params ||= block
    end

    def request_body(&block)
      @request_body ||= block
    end

    def request_path(&block)
      @request_path ||= block
    end

    def page_params!
      @page_params = true
    end

    def page_params?
      @page_params
    end

    def error_map
      @error_map ||= {
        invalid: [422, {
          'error'       => 'RecordInvalid',
          'description' => 'Record validation errors',
        },],
        not_found: [404, {
          'error'       => 'RecordNotFound',
          'description' => 'Not found',
        },],
      }
    end
  end

  attr_reader :params

  def call(*args)
    params = args.last.is_a?(Hash) ? args.pop : {}
    @params = Cistern::Hash.stringify_keys(params)

    dispatch
  end

  def page_params!(options)
    url = options.delete('url')

    page_params = if url
                    Faraday::NestedParamsEncoder.decode(URI.parse(url).query)
                  else
                    Cistern::Hash.stringify_keys(options)
                  end
    Cistern::Hash.slice(page_params, 'per_page', 'page', 'query', 'include')
  end

  def page_params?
    self.class.page_params?
  end

  def request_params
    page_params = (page_params!(params) if page_params?)

    if self.class.request_params
      self.class.request_params.call(self)
    else
      page_params
    end
  end

  def request_path
    case (generator = self.class.request_path)
    when Proc then
      generator.call(self)
    else raise ArgumentError, "Couldn't generate request_path from #{generator.inspect}"
    end
  end

  def request_body
    case (generator = self.class.request_body)
    when Proc then
      generator.call(self)
    when NilClass then nil
    else raise("Invalid request body generator: #{generator.inspect}")
    end
  end

  def pluralize(word)
    pluralized = word.dup
    [[/y$/, 'ies'], [/$/, 's']].find { |regex, replace| pluralized.gsub!(regex, replace) if pluralized.match(regex) }
    pluralized
  end

  def data
    cistern.data
  end

  def html_url_for(path)
    File.join(cistern.url, path.to_s)
  end

  def url_for(path, options = {})
    URI.parse(
      File.join(cistern.url, '/api/v2', path.to_s),
    ).tap do |uri|
      query = options[:query]
      query && (uri.query = Faraday::NestedParamsEncoder.encode(query))
    end.to_s
  end

  def real(params = {})
    cistern.request(method: self.class.request_method,
                    path: request_path,
                    body: request_body,
                    url: params['url'],
                    params: request_params,)
  end

  def real_request(params = {})
    request({
      method: self.class.request_method,
      path: request_path(params),
      body: request_body(params),
    }.merge(cistern.hash.slice(params, :method, :path, :body, :headers),),)
  end

  def timestamp
    Time.now.iso8601
  end

  def mock_response(body, options = {})
    response(
      method: self.class.request_method,
      path: options[:path] || request_path,
      request_body: request_body,
      response_body: body,
      headers: options[:headers] || {},
      status: options[:status]  || 200,
      params: options[:params]  || request_params,
    )
  end

  def find!(collection, identity, options = {})
    resource = cistern.data[collection][identity.to_i]
    resource || error!(options[:error] || :not_found, options)
  end

  def delete!(collection, identity, options = {})
    cistern.data[collection].delete(identity.to_i) ||
      error!(options[:error] || :not_found, options)
  end

  def error!(type, options = {})
    status, body = self.class.error_map[type]
    body['details'] = options[:details] if options[:details]

    response(
      path: request_path,
      status: status,
      body: body,
    )
  end

  def resources(collection, options = {})
    page = collection.is_a?(Array) ? collection : cistern.data[collection.to_sym].values
    root = options.fetch(:root) { !collection.is_a?(Array) && collection.to_s }

    mock_response(
      root    => page,
      'count' => page.size,
    )
  end

  def page(collection, options = {})
    url_params = options[:params] || params
    page_params = page_params!(params)

    page_size  = (page_params.delete('per_page') || 50).to_i
    page_index = (page_params.delete('page') || 1).to_i
    root       = options.fetch(:root) { !collection.is_a?(Array) && collection.to_s }
    path       = options[:path] || request_path

    offset     = (page_index - 1) * page_size

    resources   = collection.is_a?(Array) ? collection : cistern.data[collection.to_sym].values
    count       = resources.size
    total_pages = (count / page_size) + 1

    next_page = if page_index < total_pages
                  url_for(path, query: { 'page' => page_index + 1, 'per_page' => page_size }.merge(url_params))
                end
    previous_page = if page_index > 1
                      url_for(path, query: { 'page' => page_index - 1, 'per_page' => page_size }.merge(url_params))
                    end

    resource_page = resources.slice(offset, page_size)

    body = {
      root            => resource_page,
      'count'         => count,
      'next_page'     => next_page,
      'previous_page' => previous_page,
    }

    response(
      body: body,
      path: path,
    )
  end

  # @fixme
  # id values are validate for format / type
  #
  # {
  #   "error": {
  #     "title": "Invalid attribute",
  #     "message": "You passed an invalid value for the id attribute. must be an integer"
  #   }
  # }
  # @note
  #
  # \@request_body is special because it's need for spec assertions but
  # {Faraday::Env} replaces the request body with the response body after
  # the request and the reference is lost
  def response(options = {})
    body                 = options[:response_body] || options[:body]
    method               = options[:method]        || :get
    params               = options[:params]
    cistern.last_request = options[:request_body]
    status               = options[:status] || 200

    path = options[:path]
    url  = options[:url] || url_for(path, query: params)

    request_headers  = { 'Accept'       => 'application/json' }
    response_headers = { 'Content-Type' => 'application/json; charset=utf-8' }

    # request phase
    # * :method - :get, :post, ...
    # * :url    - URI for the current request; also contains GET parameters
    # * :body   - POST parameters for :post/:put requests
    # * :request_headers

    # response phase
    # * :status - HTTP response status code, such as 200
    # * :body   - the response body
    # * :response_headers
    env = Faraday::Env.from(
      method: method,
      url: URI.parse(url),
      body: body,
      request_headers: request_headers,
      response_headers: response_headers,
      status: status,
    )

    Faraday::Response::RaiseError.new.on_complete(env) ||
      Faraday::Response.new(env)
  rescue Faraday::Error::ClientError => e
    raise Zendesk2::Error, e
  end
end
