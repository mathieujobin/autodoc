require "action_dispatch/http/request"
require "active_support/core_ext/hash/slice"
require "active_support/core_ext/string/strip"
require "uri"
require "erb"
require "pathname"

module Autodoc
  class Document
    DEFAULT_DOCUMENT_PATH_FROM_EXAMPLE = ->(example) do
      example.file_path.gsub(%r<\./spec/[^/]+/(.+)_spec\.rb>, '\1.md')
    end

    def self.render(*args)
      new(*args).render
    end

    def initialize(context, example)
      @context = context
      @example = example
    end

    def pathname
      @pathname ||= begin
        Autodoc.configuration.pathname + document_path_from_example.call(example)
      end
    end

    def render
      ERB.new(Autodoc.configuration.template, nil, "-").result(binding)
    end

    def title
      "#{method} #{path}"
    end

    def identifier
      title.gsub(" ", "-").gsub(/[:\/]/, "").downcase
    end

    private

    def document_path_from_example
      Autodoc.configuration.document_path_from_example || DEFAULT_DOCUMENT_PATH_FROM_EXAMPLE
    end

    def example
      if ::RSpec::Core::Version::STRING.match /\A(?:3\.|2.99\.)/
        @example
      else
        @context.example
      end
    end

    def request
      @request ||= begin
        if using_rack_test?
          ActionDispatch::Request.new(@context.last_request.env)
        else
          @context.request
        end
      end
    end

    def response
      @response ||= begin
        if using_rack_test?
          @context.last_response
        else
          @context.response
        end
      end
    end

    def method
      request.method
    end

    def request_header
      table = request_header_from_fixed_keys
      table.merge!(request_header_from_http_prefix)
      table.reject! {|key, value| value.blank? }
      table = Hash[table.map {|key, value| [key.split(?_).map(&:downcase).map(&:camelize).join(?-), value] }]
      table.except!(*Autodoc.configuration.suppressed_request_header)
      table.map {|key, value| [key, value].join(": ") }.sort.join("\n")
    end

    def request_header_from_http_prefix
      request.headers.inject({}) do |table, (key, value)|
        if key.start_with?("HTTP_")
          table.merge(key.gsub(/^HTTP_/, "") => value)
        else
          table
        end
      end
    end

    def request_header_from_fixed_keys
      table = request.headers
      table = table.env if table.respond_to?(:env)
      table.slice("CONTENT_TYPE", "CONTENT_LENGTH", "LOCATION")
    end

    def request_http_version
      request.env["HTTP_VERSION"] || "HTTP/1.1"
    end

    def request_query
      "?#{URI.unescape(request.query_string)}" unless request.query_string.empty?
    end

    def request_body_section
      "\n\n#{request_body}" if request_body.present?
    end

    def request_body
      if instance_variable_defined?(:@request_body)
        @request_body
      else
        @request_body = begin
          case
          when request.try(:content_type) == "multipart/form-data"
            "multipart/form-data"
          when request.headers["Content-Type"].try(:include?, "application/json")
            request_body_parsed_as_json
          else
            request.body.string
          end
        end
      end
    end

    def request_body_parsed_as_json
      JSON.pretty_generate(JSON.parse(request.body.string))
    rescue JSON::ParserError
    end

    def response_http_version
      response.env["HTTP_VERSION"] || "HTTP/1.1"
    end

    def response_header
      table = response.headers.clone
      table.except!(*Autodoc.configuration.suppressed_response_header)
      table.map {|key, value| [key, value].join(": ") }.sort.join("\n")
    end

    def response_http_version
      response.header["HTTP_VERSION"] || "HTTP/1.1"
    end

    def response_body_section
      "\n\n#{response_body}" if response_body.present?
    end

    def response_body
      if instance_variable_defined?(:@response_body)
        @response_body
      else
        @response_body = begin
          case
          when response.header["Content-Type"].try(:include?, "image/")
            response.header["Content-Type"]
          when response.header["Content-Type"].try(:include?, "application/json")
            response_body_parsed_as_json
          else
            response.body
          end
        end
      end
    end

    def response_body_parsed_as_json
      JSON.pretty_generate(JSON.parse(response.body))
    rescue JSON::ParserError
      "\n" + Nokogiri::XML(response_body_raw){ |config| config.strict }.to_xml
    rescue Nokogiri::XML::SyntaxError
    end

    def controller
      request.params[:controller]
    end

    def action
      request.params[:action]
    end

    def using_rack_test?
      !!defined?(Rack::Test::Methods) && @context.class.ancestors.include?(Rack::Test::Methods)
    end

    def transaction
      @transaction ||= Autodoc::Transaction.build(@context)
    end

    def description
      if @context.respond_to?(:description)
        @context.description.strip_heredoc
      else
        "#{example.description.capitalize}."
      end
    end

    def path
      example.full_description[%r<(GET|POST|PATCH|PUT|DELETE) ([^ ]+)>, 2]
    end

    def parameters_section
      if has_validators? && parameters.present?
        "\n### Parameters\n#{parameters}\n"
      end
    end

    def param2string params
      param = []
      params.each_pair{|key, val|
        if val.is_a?(Array)
          val.each{|val2|
            param << "#{key}[]=#{val2}"
          }
        elsif val.is_a?(Hash)
          val.each_pair{|key2, val2|
            param << "#{key}[#{key2}]=#{val2}"
          }
        else
          param << "#{key}=#{val}"
        end
      }
      param.join('&')
    end
    def example_get_section 
      if request.GET.present?
        "\n### example GET\n#{param2string(request.GET)}\n"
      end
    end
    
    def example_post_section
      if request.POST.present?
        "\n### example POST\n#{param2string(request.POST)}\n"
      end
    end

    def parameters
      validators.map {|validator| Parameter.new(validator) }.join("\n")
    end

    def has_validators?
      !!(defined?(WeakParameters) && validators)
    end

    def validators
      if defined?(Sinatra)
        WeakParameters.stats[method][request.env["PATH_INFO"]].try(:validators)
      else
        WeakParameters.stats[controller][action].try(:validators)
      end
    end

    class Parameter
      attr_reader :validator

      def initialize(validator)
        @validator = validator
      end

      def to_s
        string = ""
        string << "#{body}#{payload}"

        if validator.respond_to? :validators
          validator.validators.each do |x|
            string << "\n"
            string << Parameter.new(x).to_s.indent(2)
          end
        end

        string
      end

      private

      def body
        if validator.key.nil?
          "* #{validator.type}"
        else
          "* `#{validator.key}` #{validator.type}"
        end
      end

      def payload
        string = ""
        string << " (#{assets.join(', ')})" if assets.any?
        string << " - #{validator.options[:description]}" if validator.options[:description]
        string
      end

      def assets
        @assets ||= [required, only, except, comment].compact
      end

      def required
        "required" if validator.required?
      end

      def only
        "only: `#{validator.options[:only].inspect}`" if validator.options[:only]
      end

      def except
        "except: `#{validator.options[:except].inspect}`" if validator.options[:except]
      end
      
      def comment
        "comment: `#{validator.options[:comment].inspect}`" if validator.options[:comment]
      end
    end
  end
end
