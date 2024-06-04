require "option_parser"
require "termios"
require "bit_array"
require "http/client"

lib LibC
  fun cfsetispeed(termios_p : Termios*, speed : SpeedT) : Int
  fun cfsetospeed(termios_p : Termios*, speed : SpeedT) : Int
  VTIME = 5 # somehow missing in src/lib_c/*/c/termios.cr
end

struct Ut60eSerial
    # note that different modes of UT60E work with different period
    # this value should smaller that the shortest period
    MIN_FRAME_PERIOD = 0.3
    FRAME_SIZE = 14

    @buffer = Bytes.new(FRAME_SIZE)

    def initialize(path : String)
        @serial_file = File.open(path)
        raise "Not a serial device" unless @serial_file.tty?
        raise "Cannot read serial device attributes" unless LibC.tcgetattr(@serial_file.fd, out mode) == 0

        LibC.cfsetispeed(pointerof(mode), Termios::BaudRate::B2400)
        LibC.cfsetospeed(pointerof(mode), Termios::BaudRate::B2400)

        # ControlMode
        mode.c_cflag &= ~(Termios::ControlMode::PARENB | Termios::ControlMode::PARODD).value
        mode.c_cflag |= (Termios::ControlMode::CLOCAL | Termios::ControlMode::CREAD).value
        mode.c_cflag |= (Termios::ControlMode::CSTOPB).value
        mode.c_cflag = (mode.c_cflag & ~Termios::ControlMode::CSIZE.value) | Termios::ControlMode::CS8.value

        # InputMode
        mode.c_iflag &= ~Termios::InputMode::IGNBRK.value
        mode.c_iflag &= ~(Termios::InputMode::IXON | Termios::InputMode::IXOFF | Termios::InputMode::IXANY).value

        # LocalMode
        mode.c_lflag = 0

        # OutputMode
        mode.c_oflag = 0

        # wait for either FRAME_SIZE characters or 0.5 second
        mode.c_cc[LibC::VMIN]  = FRAME_SIZE.to_u8
        mode.c_cc[LibC::VTIME] = (10 * MIN_FRAME_PERIOD).to_u8

        raise "Cannot write serial device attributes" unless LibC.tcsetattr(@serial_file.fd, Termios::LineControl::TCSANOW, pointerof(mode))
    end
    
    # Returns nil if we started to receive in the middle of the frame. Otherwise it receives bytes.
    def read
        bytes_count = @serial_file.read(@buffer)
        @buffer unless bytes_count != @buffer.size
    end
end


DIGIT = {
#    7 6 5 4 3 2 1
    {0,1,1,1,1,1,1} => 0,
    {0,0,0,0,1,1,0} => 1,
    {1,0,1,1,0,1,1} => 2,
    {1,0,0,1,1,1,1} => 3,
    {1,1,0,0,1,1,0} => 4,
    {1,1,0,1,1,0,1} => 5,
    {1,1,1,1,1,0,1} => 6,
    {0,0,0,0,1,1,1} => 7,
    {1,1,1,1,1,1,1} => 8,
    {1,1,0,1,1,1,1} => 9,
    {0,0,0,0,0,0,0} => 0,   # space is considered as 0
    {0,1,1,1,0,0,0} => 0/0, # L (overflow) is interpreted as NaN
}

DIVIDER = {
    {0,0,0} => 1,
    {1,0,0} => 10,
    {0,1,0} => 100,
    {0,0,1} => 1000,
}

SI_PREFIX = {
    {0,0,0,0,0} => "",
    {1,0,0,0,0} => "M",
    {0,1,0,0,0} => "k",
    {0,0,1,0,0} => "m",
    {0,0,0,1,0} => "u",
    {0,0,0,0,1} => "n",
}

UNIT = {
    {1,0,0,0,0,0,0} => "percent",
    {0,1,0,0,0,0,0} => "F",
    {0,0,1,0,0,0,0} => "Ohm",
    {0,0,0,1,0,0,0} => "A",
    {0,0,0,0,1,0,0} => "V",
    {0,0,0,0,0,1,0} => "Hz",
    {0,0,0,0,0,0,1} => "Celsius",
}

ACDC = {
    {0,0} => "",
    {1,0} => "~",
    {0,1} => "",
}

struct Ut60eDecoder
    @buffer : Bytes
    
    def initialize(@buffer : Bytes)
        @buffer.each_with_index do |b, index|
            raise "Incorrect byte ##{index}" unless index + 1 == b >> 4
        end
    end
    
    private def split4(byte_index)
        byte = @buffer[byte_index]
        3.downto(0).to_a.map { |i| 1 & (byte >> i) }
    end
    
    def decode
        ac, dc, auto, rs232c = split4(0)
        minus, a5, a6, a1 = split4(1)
        a4, a3, a7, a2 = split4(2)
        p1, b5, b6, b1 = split4(3)
        b4, b3, b7, b2 = split4(4)
        p2, c5, c6, c1 = split4(5)  
        c4, c3, c7, c2 = split4(6)
        p3, d5, d6, d1 = split4(7)
        d4, d3, d7, d2 = split4(8)
        micro, nano, kilo, diode = split4(9)
        milli, percent, mega, beep = split4(10)
        farad, ohm, delta, hold = split4(11)
        amper, volt, hertz, battery = split4(12)
        _, unknown, _, celsius = split4(13)
        # TrueRMS desn't seem to have dedicated bit
        
        begin
            dig_a = DIGIT[{a7,a6,a5,a4,a3,a2,a1}]
            dig_b = DIGIT[{b7,b6,b5,b4,b3,b2,b1}]
            dig_c = DIGIT[{c7,c6,c5,c4,c3,c2,c1}]
            dig_d = DIGIT[{d7,d6,d5,d4,d3,d2,d1}]
            divider = DIVIDER[{p3,p2,p1}]
            si_prefix = SI_PREFIX[{mega, kilo, milli, micro, nano}]
            unit = UNIT[{percent, farad, ohm, amper, volt, hertz, celsius}]
            acdc = ACDC[{ac,dc}]
        rescue
            raise "Incorrect symbol"
        end
        inverter = minus == 1 ? -1 : 1
        
        value = inverter * (1000 * dig_a + 100 * dig_b + 10 * dig_c + dig_d) / divider
        {value, si_prefix + unit + acdc}
    end
end

struct DbPublisher
    def initialize(@address : String)
    end
    
    def publish(value, unit)
        unless value.nan?
            begin
                body = "put " + unit + " " + Time.local.to_unix.to_s + " " + value.to_s
                resp = HTTP::Client.post(@address + "/api/put", body: body)
            rescue ex
                STDERR.puts "Error: " + ex.to_s
            end            
        end
    end
end

struct DbPublisherDummy
    def publish(value, unit)
    end
end

opt_device = nil
opt_database = nil
OptionParser.parse do |parser|
    parser.banner = "Usage: ut60e_collector"
    parser.on("-d DEVICE", "--dmm=DEVICE", "Device, e.g. '/dev/ttyUSB0' [required]") { |device| opt_device = device }
    parser.on("-D ADDRESS", "--database=ADDRESS", "OpenTSDB address, e.g. 'localhost:6182'") { |address| opt_database = address }
    parser.on("-h", "--help", "Show this help") do
        puts parser
        exit
    end
end

unless opt_device
    STDERR.puts "Missing option: --dmm"
    exit
end
dev = Ut60eSerial.new opt_device.not_nil!

if opt_database
    pub = DbPublisher.new opt_database.not_nil!
else
    pub = DbPublisherDummy.new
end


loop do
    frame = dev.read
    next unless frame
    begin
        dec = Ut60eDecoder.new frame
        value, unit = dec.decode
    rescue ex
        STDERR.puts "Error: " + ex.to_s
    else
        puts value.to_s + " " + unit
        pub.publish value, unit
    end
end
