class Poi < ActiveRecord::Base

  serialize :tags, Hash

  has_many :poi_categories
  has_many :categories, through: :poi_categories
  has_many :changesets, -> { order('changesets.created_at DESC') }
  has_many :users, -> { distinct }, :through => :changesets

  validates :osm_type, :name, :lat, :lon, presence: true
  validates :osm_type, inclusion: { in: %w(node way relation) }

  before_save :set_tags

  attr_accessor :category_id

  scope :closest, lambda { |lat, lon, count=20, distance=(1.63*2)|
    select("*,
      (6378*acos(cos(radians(#{lat}))*cos(radians(lat))*
      cos(radians(lon)-radians(#{lon}))+sin(radians(#{lat}))*
      sin(radians(lat)))) AS distance").
    where("lat BETWEEN #{lat-(distance/111.045)} AND #{lat+(distance/111.045)} AND
           lon BETWEEN #{lon}-(#{distance}/(111.045 * COS(RADIANS(#{lat})))) AND
                       #{lon}+(#{distance}/(111.045 * COS(RADIANS(#{lat}))))
           AND osm_id > 0").
    order('distance').
    limit(count)
  }

  def create_osm_poi(user, poi_changes)
    changeset = Changeset.create(:user=>user, :poi=>self, :poi_changes=>poi_changes, :created=>true)
    url = "#{OSM_API_BASE}/#{osm_type}/create"
    xml = to_xml(changeset)
    response = user.osm_access_token.put(url, xml, { 'Content-Type' => 'application/xml' })
    changeset.close_remote
    if response.code=='200'
      self.update_attributes(:osm_id => response.body)
    else
      raise response.class.name
    end
  end

  def update_osm_poi(user, poi_changes)
    changeset = Changeset.create(:user=>user, :poi=>self, :poi_changes=>poi_changes, :created=>false)
    url = "#{OSM_API_BASE}/#{osm_type}/#{osm_id}"
    xml = to_xml(changeset)
    response = user.osm_access_token.put(url, xml, { 'Content-Type' => 'application/xml' })
    changeset.close_remote
    if response.code=='200'
      self.update_attributes(:version => response.body)
    else
      raise response.class.name
    end
  end

  def display_category
    if categories.count <= 1
      categories.first
    else
      # category with parent is more specific, preferred
      categories.select { |c| !c.parent_id.nil? }.first
    end
  end

  def self.decode_tags(tags)
    return unless tags
    hash = {}
    tags.each do |tag|
      key = tag['k'].gsub(':', '_')
      hash[key] = tag['v']
    end
    hash.symbolize_keys
  end

  def set_tags
    self.tags[:name] = name unless name.nil?
    self.tags[:addr_housenumber] = addr_housenumber unless addr_housenumber.nil?
    self.tags[:addr_street] = addr_street unless addr_street.nil?
    self.tags[:addr_city] = addr_city unless addr_city.nil?
    self.tags[:addr_postcode] = addr_postcode unless addr_postcode.nil?
    self.tags[:phone] = phone unless phone.nil?
    self.tags[:website] = website unless website.nil?
    categories.map(&:tags).each { |th| self.tags = tags.merge(th.symbolize_keys) }
    parents = categories.map(&:parent).compact
    parents.map(&:tags).each { |th| self.tags = tags.merge(th.symbolize_keys) }
    self.tags = self.tags.delete_if { |k,v| v.blank? }
  end

  private

  def to_xml(changeset)
    xml = "<osm>"
    xml << "<#{osm_type} visible=\"true\" "
    xml << "id=\"#{osm_id}\" " unless osm_id.nil?
    xml << "version=\"#{version}\" " unless version.nil?
    xml << "changeset=\"#{changeset.osm_id}\" timestamp=\"#{Time.now.utc}\" "
    xml << "user=\"#{changeset.user.display_name}\" uid=\"#{changeset.user.uid}\" "
    xml << "lat=\"#{lat}\" lon=\"#{lon}\">"
    xml << encode_tags
    xml << "</#{osm_type}>"
    xml << "</osm>"
    xml
  end

  def encode_tags
    self.set_tags
    xml = ''
    self.tags.each do |k,v|
      next if osm_type!='node' && (k=='lat' || k=='lon')
      key = k.to_s.gsub('_', ':')
      val = CGI::escapeHTML(v)
      xml << "<tag k=\"#{key}\" v=\"#{val}\"/>"
    end
    xml
  end

end
