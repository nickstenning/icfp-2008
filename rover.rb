#!/usr/bin/env ruby -w

require "socket"
require "yaml"
require "matrix"

class String
  def underscore
    gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
    gsub(/([a-z\d])([A-Z])/,'\1_\2').
    downcase
  end
end

class Numeric
  def to_rad
    self.quo(360) * 2*Math::PI
  end

  def to_deg
    self.quo(2*Math::PI) * 360
  end
end

class Position < Vector
  def self.unit_north
    self[0, 1]
  end
  
  def self.from_vector( vector )
    self[*vector.to_a]
  end
  
  def self.heading_between( from, to )
    delta = (to - from).normalize
    angle = Math.acos(delta.inner_product(Position.unit_north)).to_deg
    if self.from_vector(delta).x < 0
      return 360 - angle
    else
      return angle
    end
  end
  
  def -( other )
    from_vector(super)
  end
  
  def +( other )
    from_vector(super)
  end
  
  def x
    self[0]
  end
  
  def y
    self[1]
  end
  
  def x=( val )
    @elements[0] = val
  end
  
  def y=( val )
    @elements[1] = val
  end
  
  def normalize
    collect do |el|
      el / r
    end
  end
  
  def heading_to( other )
    self.class.heading_between(self, other)
  end
  
  def heading_from( other )
    self.class.heading_between(other, self)
  end
  
  def from_vector( vector )
    self.class.from_vector(vector)
  end
end

##

module Mars
  
  class CommunicationsManager
    TAGS = ::YAML::load_file('tags_spec.yml')
    OBJECTS = ::YAML::load_file('objects_spec.yml')
  
    attr_writer :rover
    
    def initialize
      @host = "127.0.0.1"
      @port = 17676
      @stream = []
      @chunk = ""
      @parameters = {}
    end
  
    def run
      raise "Could not open comms socket" unless open_communications
    
      connect_rover
    
      loop do
        parse_stream
      end
    end
  
    def open_communications
      @socket = TCPSocket.new(@host, @port)
    end
  
    def connect_rover
      @rover.socket = @socket
    end
  
    def read_stream
      @stream << @socket.recv(255)
    end
  
    def parse_stream
      if c = @stream.shift
        @chunk << c
        if p = @chunk.index(?;)
          process_chunk @chunk[0...p]
          @chunk = @chunk[p+1..-1]
        end
      else
        read_stream
      end
    end

    def process_chunk( string )
      data = string.split
      type = TAGS[data.shift.intern][:type]
      send("process_#{type}_data", data)
    end
  
    def process_initialization_data( data )
      read_message(:I, data) do |name, value|
        @rover.parameters[name] = value
      end
    
      puts "Starting run, parameters:"
    
      y @rover.parameters
    end
  
    def process_telemetry_data( data )
      data_packet = {}
    
      read_message(:T, data) do |name, value|
        data_packet[name] = value
      end
    
      objects_start = TAGS[:T][:format].length
    
      objects = data[objects_start..-1].inject([]) do |obj_list, snippet|
        if OBJECTS.keys.include? snippet.intern
          obj_list << [snippet.intern]
        else
          obj_list.last << snippet
        end
        next obj_list
      end
    
      data_packet[:objects] = objects.map { |obj_params| create_object(*obj_params) }

      @rover.process(data_packet)
    end
  
    def process_bounce_data( data )
      puts "Bounced."
    end
  
    def process_crater_data( data )
      puts "Oops. Cratered!"
    end
  
    def process_kill_data( data )
      puts "Aaargh! Killed by a Martian."
    end
  
    def process_success_data( data )
      puts "Wahey, we successfully got home!"
    end
  
    def process_end_of_run_data( data )
      data_packet = {}
    
      read_message(:E, data) do |name, value|
        data_packet[name] = value
      end
    
      puts "End of run. Score: #{data_packet[:score]}"
      
      @rover.reset!
    end
  
    protected
  
    def read_message( tag, data )
      TAGS[tag][:format].each_with_index do |(name, datatype), index|
        yield name, data[index].send("to_#{datatype}")
      end
    end
  
    def create_object( tag, *data )
      klass = Object.const_get(OBJECTS[tag][:type])
      obj = klass.new
    
      OBJECTS[tag][:format].each_with_index do |(name, datatype), index|
        obj.send("#{name}=", data[index].send("to_#{datatype}"))
      end
      
      return obj
    end
  
  end

  class RoverRunner
  
    attr_writer :socket
    attr_accessor :parameters
  
    LINEAR_STATE_ORDER = [:b, :-, :a]
    LINEAR_STATES = {
      :accelerate => :a, 
      :brake      => :b, 
      :roll       => :-
    }
    
    ROTATION_STATE_ORDER = [:L, :l, :-, :r, :R]
    ROTATION_STATES = {
      :right      => :r, 
      :left       => :l,
      :hard_right => :R,
      :hard_left  => :L, 
      :straight   => :-
    }
  
    def initialize
      reset!
    end
    
    def reset!
      @map = Map.new
      @parameters = {}
      @packets = []
      @temporary_target = nil

      @map.add_object(Origin.new)
    end
  
    def process( packet )
      #@packets << packet
      @packets = [packet]
      
      @map.add_objects(*packet[:objects])
      
      if avoiding_collision? or going_to_collide?
        avoid_collision
      elsif @map.find_object(:home)
        head_for :home
      else
        head_for :origin
      end
    end
    
    def position
      Position[latest[:vehicle_x], latest[:vehicle_y]]
    end
    
    def heading
      (-latest[:vehicle_dir] % 360) + 90
    end
  
    def accelerate
      cmd 'a'
    end
  
    def brake
      cmd 'b'
    end
  
    def left
      cmd 'l'
    end
  
    def right
      cmd 'r'
    end
    
    def latest
      @packets.last
    end
  
    def cmd( str )
      puts "Sending command: #{str}"
      @socket.write str + ';'
    end
    
    ##
    
    def head_for( location )
      location = @map.find_object(location) unless location.respond_to? :position
      if pointing_towards?( location )
        set_rotation_state(:straight)
        set_linear_state(:accelerate)
      else
        set_linear_state(:roll)
        turn_towards( location )
      end
    end
    
    def speed
      latest[:vehicle_speed]
    end
    
    def linear_state
      latest[:vehicle_ctl][0,1].intern
    end
    
    def rotation_state
      latest[:vehicle_ctl][1,2].intern
    end
    
    def set_linear_state( state )
      state = LINEAR_STATES[state]
      diff = LINEAR_STATE_ORDER.index(state) - LINEAR_STATE_ORDER.index(linear_state)
      if diff > 0
        accelerate
      elsif diff < 0
        brake
      end
    end

    def set_rotation_state( state )
      state = ROTATION_STATES[state]
      diff = ROTATION_STATE_ORDER.index(state) - ROTATION_STATE_ORDER.index(rotation_state)
      if diff > 0
        right
      elsif diff < 0
        left
      end
    end
    
    def pointing_towards?( object, tolerance=5 )
      range = ((heading-tolerance)..(heading+tolerance))
      range.include? position.heading_to(object.position)
    end
    
    def turn_towards( object )
      object_heading = position.heading_to(object.position)
      case (object_heading - heading) % 360
      when 0..20
        set_rotation_state(:right)
      when 20..180
        set_rotation_state(:hard_right)
      when 180..340
        set_rotation_state(:hard_left)
      when 340..360
        set_rotation_state(:left)
      else
        raise "Oops! Heading difference out of range!"
      end
    end
    
    def going_to_collide?
      in_path = nearest_objects(speed * 2).select do |obj|
        in_path? obj
      end
      if in_path.any?
        @collision_prospect = nearest_of( in_path )
        if @collision_prospect.kind_of?(Martian)
          return false
        end34
        puts "Might collide with #{@collision_prospect}"
        return true
      end
    end
    
    def in_path? obj
      case position.heading_to(obj.position)
      when 358..360, 0..2
        true
      end
    end
    
    def avoiding_collision?
      !!@temporary_target
    end
    
    def avoid_collision
      if @collision_prospect
        hyp = @collision_prospect.r + 1.0 # radius plus tolerance to avoid the obstacle.
        offset = Position[-hyp * Math::cos(heading.to_rad), hyp * Math::sin(heading.to_rad)]
        waypoint = @collision_prospect.position + offset
        @temporary_target = Target.new(*waypoint)
        @collision_prospect = nil
        puts "Set temporary target: #{@temporary_target}"
      end
      
      if @temporary_target
        if distance_to( @temporary_target ) < 10
          @temporary_target = nil
        else
          head_for( @temporary_target )
        end
      end
    end
    
    def nearest_objects( distance )
      @map.select { |obj| distance_to(obj) < distance }
    end
    
    def nearest_of( obj_list )
      obj_list[1..-1].inject(obj_list[0]) do |nearest, obj|
        if distance_to(obj) < distance_to(nearest)
          next obj
        else
          next nearest
        end
      end
    end
    
    def distance_to( object )
      (object.position - position).r
    end
    
  end
  
  class Map
    
    include Enumerable
    
    def initialize
      @registry = []
    end
    
    def add_objects( *objects )
      @registry |= objects
    end
    alias_method :add_object, :add_objects
    
    def find_object( identifier )
      find_objects( identifier ).first
    end
    
    def find_objects( identifier )
      @registry.select { |obj| obj.name == identifier }
    end
    
    def each(*args, &block)
      @registry.each(*args, &block)
    end
    
  end
  
  class EnvObject
    attr_accessor :x, :y
    def initialize(x=0, y=0)
      @x = x
      @y = y
    end
    
    def name
      self.class.to_s.underscore.split('::').last.intern
    end
    
    def position
      Position[x, y]
    end
    
    def ==( other )
      x == other.x and y == other.y and name == other.name
    end
  end
  
  class StationaryObject < EnvObject
    attr_accessor :r
    def initialize(x=0, y=0, r=1)
      @r = r
      super(x, y)
    end
    
    def ==( other )
      super and r == other.r
    end
  end
  
  class Target < EnvObject; end
  class Origin < EnvObject; end
  
  class Home < StationaryObject; end
  class Boulder < StationaryObject; end
  class Crater < StationaryObject; end
  
  class MovingObject < EnvObject
    attr_accessor :dir, :speed
    
    # FIXME: all moving objects are not the same!
  end
  
  class Martian < MovingObject; end
  
end

if __FILE__ == $0
  include Mars
  
  comm = CommunicationsManager.new
  comm.rover = RoverRunner.new
  comm.run
  
  trap(:INT) { exit }
  sleep
end