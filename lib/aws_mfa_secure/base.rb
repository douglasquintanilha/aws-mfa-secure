require "aws-sdk-core"
require "fileutils"
require "json"
require "memoist"
require "time"
require "active_support/core_ext/string"
require "active_support/core_ext/hash"

module AwsMfaSecure
  class MfaError < StandardError; end

  class Base
    extend Memoist

    def iam_mfa?
      return false unless mfa_serial

      # The iam_mfa? check will only return true for the case when mfa_serial is set and access keys are used.
      # This is because for assume role cases, the current aws cli tool supports mfa_serial already.
      # Sending session AWS based access keys intefere with the current aws cli assume role mfa_serial support
      aws_access_key_id = aws_configure_get(:aws_access_key_id)
      aws_secret_access_key = aws_configure_get(:aws_secret_access_key)
      role_arn = aws_configure_get(:role_arn)
      source_profile = aws_configure_get(:source_profile)

      aws_access_key_id && aws_secret_access_key && !role_arn && !source_profile
    end

    def fetch_creds?
      !good_session_creds?
    end

    def good_session_creds?
      return false unless File.exist?(session_creds_path)

      expiration = Time.parse(credentials["expiration"])
      Time.now.utc < expiration # not expired
    end

    def credentials
      JSON.load(IO.read(session_creds_path))
    end
    memoize :credentials

    def save_creds(credentials)
      FileUtils.mkdir_p(File.dirname(session_creds_path))
      IO.write(session_creds_path, JSON.pretty_generate(credentials))
    end

    def session_creds_path
      "#{ENV['HOME']}/.aws/aws-mfa-secure-sessions/#{@aws_profile}"
    end

    def get_session_token(shell: false)
      retries = 0
      begin
        $stderr.print "Please provide your MFA code: "
        token_code = $stdin.gets.strip
        options = {
          serial_number: mfa_serial,
          token_code: token_code,
        }
        options[:duration_seconds] = ENV['AWS_MFA_TTL'] if ENV['AWS_MFA_TTL']

        if shell
          shell_get_session_token(options, token_code) # mimic ruby sdk
        else # ruby sdk
          sts.get_session_token(options)
        end
      rescue Aws::STS::Errors::ValidationError, Aws::STS::Errors::AccessDenied, MfaError => e
        $stderr.puts "#{e.class}: #{e.message}"
        $stderr.puts "Incorrect MFA code.  Please try again."
        retries += 1
        if retries >= 3
          $stderr.puts "Giving up after #{retries} retries."
          exit 1
        end
        retry
      end
    end

    def shell_get_session_token(options, token_code)
      args = options.map { |k,v| "--#{k.to_s.gsub('_','-')} #{v}" }.join(' ')
      command = "aws sts get-session-token #{args} 2>&1"
      # puts "=> #{command}" # uncomment for debugging
      out = `#{command}`

      unless out.include?("Credentials")
        raise(MfaError, out.strip) # custom error
      end

      data = JSON.load(out)
      resp = data.deep_transform_keys { |k| k.underscore }
      # mimic ruby sdk resp
      credentials = Aws::STS::Types::Credentials.new(resp["credentials"])
      Aws::STS::Types::GetSessionTokenResponse.new(credentials: credentials)
    end

    def mfa_serial
      aws_configure_get(:mfa_serial)
    end

    def sts
      Aws::STS::Client.new
    end
    memoize :sts

    # Note the strip
    def aws_configure_get(prop)
      v = `aws configure get #{prop}`.strip
      v unless v.empty?
    end
    memoize :aws_configure_get

    def aws_profile
      ENV['AWS_PROFILE'] || 'default'
    end
  end
end
