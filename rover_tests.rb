require "rover"

describe Position do
  before(:each) do
    @origin = Position[0, 0]
    @on_y_equals_x = Position[4, 4]
    @pos = Position[5, 12]
  end
  it "should return the first element with #x" do
    @pos.x.should == 5
  end
  it "should return the second element with #y" do
    @pos.y.should == 12
  end
  it "should set the first element with #x=" do
    @pos.x = 12
    @pos.x.should == 12
  end
  it "should set the second element with #y=" do
    @pos.y = 5
    @pos.y.should == 5
  end
  it "should divide each element by the vector magnitude with #normalize" do
    vec = @pos.normalize
    vec[0].should == (5 / 13.0)
    vec[1].should == (12 / 13.0)
  end
  it "should return a normalized position vector with #normalize" do
    @pos.normalize.r.should == 1.0
  end
  it "should return the heading to another Position instance with #heading_to" do
    @origin.heading_to(@on_y_equals_x).should be_close(45.0, 0.000000001)
  end
  it "should return the heading from another Position instance with #heading_from" do
    @origin.heading_from(@on_y_equals_x).should be_close(225.0, 0.000000001)
  end
end