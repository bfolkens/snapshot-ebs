require 'net/http'

# hack to eliminate the SSL certificate verification notification
class Net::HTTP
	alias_method :old_initialize, :initialize
	def initialize(*args)
		old_initialize(*args)
		@ssl_context = OpenSSL::SSL::SSLContext.new
		@ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
	end
end
