require 'open3'

module FastlaneCore
  class DeviceManager
    class << self
      def all(requested_os_type)
        return connected_devices(requested_os_type) + simulators(requested_os_type)
      end

      def simulators(requested_os_type)
        Helper.log.info "Fetching available simulator devices" if $verbose

        @devices = []
        os_type = 'unknown'
        os_version = 'unknown'
        output = ''
        Open3.popen3('xcrun simctl list devices') do |stdin, stdout, stderr, wait_thr|
          output = stdout.read
        end

        unless output.include?("== Devices ==")
          Helper.log.error "xcrun simctl CLI broken, run `xcrun simctl list devices` and make sure it works".red
          raise "xcrun simctl not working.".red
        end

        output.split(/\n/).each do |line|
          next if line =~ /^== /
          if line =~ /^-- /
            (os_type, os_version) = line.gsub(/-- (.*) --/, '\1').split
          else
            # iPad 2 (0EDE6AFC-3767-425A-9658-AAA30A60F212) (Shutdown)
            # iPad Air 2 (4F3B8059-03FD-4D72-99C0-6E9BBEE2A9CE) (Shutdown) (unavailable, device type profile not found)
            match = line.match(/\s+([^\(]+) \(([-0-9A-F]+)\) \(([^\(]+)\)(.*unavailable.*)?/)
            if match && !match[4] && os_type == requested_os_type
              @devices << Device.new(name: match[1], os_version: os_version, udid: match[2], state: match[3], is_simulator: true)
            end
          end
        end

        return @devices
      end

      def connected_devices(requested_os_type)
        Helper.log.info "Fetching available connected devices" if $verbose

        device_types = []
        if requested_os_type == "tvOS"
          device_types = ["AppleTV"]
        elsif requested_os_type == "iOS"
          device_types = ["iPhone", "iPad"]
        end

        devices = [] # Return early if no supported devices are being searched for
        if device_types.count == 0
          return devices
        end

        usb_devices_output = ''
        Open3.popen3("system_profiler SPUSBDataType") do |stdin, stdout, stderr, wait_thr|
          usb_devices_output = stdout.read
        end

        device_uuids = []
        usb_devices_output_lines = usb_devices_output.split(/\n/)
        (0..usb_devices_output_lines.count).each do |line_index|
          line = usb_devices_output_lines[line_index]
          is_supported_device = !line.nil? && device_types.any? { |device_type| line.include?(device_type) }
          next unless is_supported_device
          usb_info_lines = 10
          (line_index + 2..line_index + usb_info_lines).each do |i| # Search usb device info for serial/UUID
            next if usb_devices_output_lines[i].nil?
            match = usb_devices_output_lines[i].match(/Serial Number: ([0-9a-f]+)/)
            if !match.nil? && match[0].length == 55
              device_uuids.push(match[1])
            end
          end
        end

        if device_uuids.count > 0 # instruments takes a little while to return so skip it if we have no devices
          instruments_devices_output = ''
          Open3.popen3("instruments -s devices") do |stdin, stdout, stderr, wait_thr|
            instruments_devices_output = stdout.read
          end

          instruments_devices_output.split(/\n/).each do |instruments_device|
            device_uuids.each do |device_uuid|
              match = instruments_device.match(/(.+) \(([0-9.]+)\) \[([0-9a-f]+)\]?/)
              if match && match[3] == device_uuid
                devices << Device.new(name: match[1], udid: match[3], os_version: match[2], state: "Booted", is_simulator: false)
                Helper.log.info "USB Device Found - \"" + match[1] + "\" (" + match[2] + ") UUID:" + match[3] if $verbose
              end
            end
          end
        end

        return devices
      end

      def clear_cache
        @devices = nil
      end

      # The code below works from Xcode 7 on
      # def all
      #   Helper.log.info "Fetching available devices" if $verbose

      #   @devices = []
      #   output = ''
      #   Open3.popen3('xcrun simctl list devices --json') do |stdin, stdout, stderr, wait_thr|
      #     output = stdout.read
      #   end

      #   begin
      #     data = JSON.parse(output)
      #   rescue => ex
      #     Helper.log.error ex
      #     Helper.log.error "xcrun simctl CLI broken, run `xcrun simctl list devices` and make sure it works".red
      #     raise "xcrun simctl not working.".red
      #   end

      #   data["devices"].each do |os_version, l|
      #     l.each do |device|
      #       next if device['availability'].include?("unavailable")
      #       next unless os_version.include?(requested_os_type)

      #       os = os_version.gsub(requested_os_type + " ", "").strip
      #       @devices << Device.new(name: device['name'], os_version: os, udid: device['udid'])
      #     end
      #   end

      #   return @devices
      # end
    end

    # Use the UDID for the given device when setting the destination
    # Why? Because we might get this error message
    # > The requested device could not be found because multiple devices matched the request.
    #
    # This happens when you have multiple simulators for a given device type / iOS combination
    #   { platform:iOS Simulator, id:1685B071-AFB2-4DC1-BE29-8370BA4A6EBD, OS:9.0, name:iPhone 5 }
    #   { platform:iOS Simulator, id:A141F23B-96B3-491A-8949-813B376C28A7, OS:9.0, name:iPhone 5 }
    #
    # We don't want to deal with that, so we just use the UDID

    class Device
      attr_accessor :name
      attr_accessor :udid
      attr_accessor :os_version
      attr_accessor :ios_version # Preserved for backwards compatibility
      attr_accessor :state
      attr_accessor :is_simulator

      def initialize(name: nil, udid: nil, os_version: nil, state: nil, is_simulator: nil)
        self.name = name
        self.udid = udid
        self.os_version = os_version
        self.ios_version = os_version
        self.state = state
        self.is_simulator = is_simulator
      end

      def to_s
        self.name
      end

      def reset
        Helper.log.info "Resetting #{self}"
        `xcrun simctl shutdown #{self.udid}` if self.state == "Booted"
        `xcrun simctl erase #{self.udid}`
        return
      end
    end
  end

  class Simulator < DeviceManager
    class << self
      def all
        return DeviceManager.all('iOS')
      end

      # Reset all simulators of this type
      def reset_all
        all.each(&:reset)
      end

      # Reset simulator by UDID or name and OS version
      # Latter is useful when combined with -destination option of xcodebuild
      def reset(udid: nil, name: nil, os_version: nil)
        match = all.detect { |device| device.udid == udid || device.name == name && device.os_version == os_version }
        match.reset if match
      end
    end
  end

  class SimulatorTV < DeviceManager
    class << self
      def all
        return DeviceManager.simulators('tvOS')
      end
    end
  end

  class SimulatorWatch < DeviceManager
    class << self
      def all
        return DeviceManager.simulators('watchOS')
      end
    end
  end
end
