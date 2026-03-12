# frozen_string_literal: true

module E2B
  class ReadyCmd
    def initialize(cmd)
      @cmd = cmd
    end

    def get_cmd
      @cmd
    end
  end

  class << self
    def wait_for_port(port)
      ReadyCmd.new("ss -tuln | grep :#{port}")
    end

    def wait_for_url(url, status_code = 200)
      ReadyCmd.new(%(curl -s -o /dev/null -w "%{http_code}" #{url} | grep -q "#{status_code}"))
    end

    def wait_for_process(process_name)
      ReadyCmd.new("pgrep #{process_name} > /dev/null")
    end

    def wait_for_file(filename)
      ReadyCmd.new("[ -f #{filename} ]")
    end

    def wait_for_timeout(timeout)
      seconds = [1, timeout.to_i / 1000].max
      ReadyCmd.new("sleep #{seconds}")
    end
  end
end
