# == Schema Information
# Schema version: 20090120184410
#
# Table name: orders
#
#  id                 :integer(4)      not null, primary key
#  supplier_id        :integer(4)
#  note               :text
#  starts             :datetime
#  ends               :datetime
#  state              :string(255)     default("open")
#  lock_version       :integer(4)      default(0), not null
#  updated_by_user_id :integer(4)
#

class Order < ActiveRecord::Base
  extend ActiveSupport::Memoizable    # Ability to cache method results. Use memoize :expensive_method
  acts_as_ordered :order => "ends"    # easyier find of next or previous model

  # Associations
  has_many :order_articles, :dependent => :destroy
  has_many :articles, :through => :order_articles
  has_many :group_orders, :dependent => :destroy
  has_many :ordergroups, :through => :group_orders
  has_one :invoice
  has_many :comments, :class_name => "OrderComment", :order => "created_at"
  belongs_to :supplier
  belongs_to :updated_by, :class_name => "User", :foreign_key => "updated_by_user_id"

  # Validations
  validates_presence_of :supplier_id, :starts
  validate_on_create :starts_before_ends, :include_articles

  # Callbacks
  after_update :update_price_of_group_orders
 
  # Finders
  named_scope :finished, :conditions => { :state => 'finished' },
    :order => 'ends DESC'
  named_scope :open, :conditions => { :state => 'open' },
    :order => 'ends DESC'
  named_scope :closed, :conditions => { :state => 'closed' },
    :order => 'ends DESC'

  # Create or destroy OrderArticle associations on create/update
  def article_ids=(ids)
    # fetch selected articles
    articles_list = Article.find(ids)
    # create new order_articles
    (articles_list - articles).each { |article| order_articles.build(:article => article) }
    # delete old order_articles
    articles.reject { |article| articles_list.include?(article) }.each do |article|
      order_articles.detect { |order_article| order_article.article_id == article.id }.destroy
    end
  end

  def open?
    state == "open"
  end

  def finished?
    state == "finished"
  end

  def closed?
    state == "closed"
  end

  # search GroupOrder of given Ordergroup
  def group_order(ordergroup)
    group_orders.first :conditions => { :ordergroup_id => ordergroup.id }
  end
  
  # Returns OrderArticles in a nested Array, grouped by category and ordered by article name.
  # The array has the following form:
  # e.g: [["drugs",[teethpaste, toiletpaper]], ["fruits" => [apple, banana, lemon]]]
  def get_articles
    order_articles.all(:include => [:article, :article_price], :order => 'articles.name').group_by { |a|
      a.article.article_category.name
    }.sort { |a, b| a[0] <=> b[0] }
  end
  memoize :get_articles
  
  # Returns the defecit/benefit for the foodcoop
  # Requires a valid invoice, belonging to this order
  def profit(options = {})
    markup = options[:with_markup] || true
    if invoice
      groups_sum = markup ? sum(:groups) : sum(:groups_without_markup)
      groups_sum - invoice.net_amount
    end
  end
  
  # Returns the all round price of a finished order
  # :groups returns the sum of all GroupOrders
  # :clear returns the price without tax, deposit and markup
  # :gross includes tax and deposit. this amount should be equal to suppliers bill
  # :fc, guess what...
  def sum(type = :gross)
    total = 0
    if type == :clear || type == :gross || type == :fc
      for oa in order_articles.ordered.all(:include => [:article,:article_price])
        quantity = oa.units_to_order * oa.price.unit_quantity
        case type
        when :clear
          total += quantity * oa.price.price
        when :gross
          total += quantity * oa.price.gross_price
        when :fc
          total += quantity * oa.price.fc_price
        end
      end
    elsif type == :groups || type == :groups_without_markup
      for go in group_orders
        for goa in go.group_order_articles
          case type
          when :groups
            total += goa.quantity * goa.order_article.price.fc_price
          when :groups_without_markup
            total += goa.quantity * goa.order_article.price.gross_price
          end
        end
      end
    end
    total
  end

  # Finishes this order. This will set the order state to "finish" and the end property to the current time.
  # Ignored if the order is already finished.
  def finish!(user)
    unless finished?
      Order.transaction do
        # Update order_articles. Save the current article_price to keep price consistency
        order_articles.all(:include => :article).each do |oa|
          oa.update_attribute(:article_price, oa.article.article_prices.first)
        end
        # set new order state (needed by notify_order_finished)
        update_attributes(:state => 'finished', :ends => Time.now, :updated_by => user)

        # TODO: delete data, which is no longer required ...
        # group_order_article_quantities... order_articles with units_to_order == 0 ? ...
      end

      # notify order groups
      notify_order_finished
    end
  end

  # TODO: I can't understand, why its going out from the group_order_articles perspective.
  # Why we can't just iterate through the order_articles?
  #
  # Updates the ordered quantites of all OrderArticles from the GroupOrderArticles.
  # This method is fired after an ordergroup has saved/updated his order.
  def update_quantities
    indexed_order_articles = {}  # holds the list of updated OrderArticles indexed by their id
    # Get all GroupOrderArticles for this order and update OrderArticle.quantity/.tolerance/.units_to_order from them...
    group_order_articles = GroupOrderArticle.all(:conditions => ['group_order_id IN (?)', group_order_ids],
                                                 :include => [:order_article])
    for goa in group_order_articles
      if (order_article = indexed_order_articles[goa.order_article.id.to_s])
        # order_article has already been fetched, just update...
        order_article.quantity = order_article.quantity + goa.quantity
        order_article.tolerance = order_article.tolerance + goa.tolerance
        order_article.units_to_order = order_article.article.calculate_order_quantity(order_article.quantity, order_article.tolerance)
      else
        # First update to OrderArticle, need to store in orderArticle hash...
        order_article = goa.order_article
        order_article.quantity = goa.quantity
        order_article.tolerance = goa.tolerance
        order_article.units_to_order = order_article.article.calculate_order_quantity(order_article.quantity, order_article.tolerance)
        indexed_order_articles[order_article.id.to_s] = order_article
      end
    end
    # Commit changes to database...
    OrderArticle.transaction do
      indexed_order_articles.each_value { | value | value.save! }
    end
  end
  
  # Sets "booked"-attribute to true and updates all Ordergroup_account_balances
  def balance(user)
    raise "Bestellung wurde schon abgerechnet" if self.booked
    transaction_note = "Bestellung: #{name}, von #{starts.strftime('%d.%m.%Y')} bis #{ends.strftime('%d.%m.%Y')}"
    transaction do
      # update Ordergroups
      group_order_results.each do |result|
        price = result.price * -1 # decrease! account balance
        Ordergroup.find_by_name(result.group_name).addFinancialTransaction(price, transaction_note, user)        
      end
      self.booked = true
      self.updated_by = user
      self.save!
    end
  end
  
  protected

  def starts_before_ends
     errors.add(:ends, "muss nach dem Bestellstart liegen (oder leer bleiben)") if (ends && starts && ends <= starts)
  end

  def include_articles
    errors.add(:order_articles, "Es muss mindestens ein Artikel ausgewählt sein") if order_articles.empty?
  end

  private
  
  # Updates the "price" attribute of GroupOrders or GroupOrderResults
  # This will be either the maximum value of a current order or the actual order value of a finished order.
  def update_price_of_group_orders
    group_orders.each { |group_order| group_order.update_price! }
  end

  # Sends "order finished" messages to users who have participated in this order.
  def notify_order_finished
    for group_order in self.group_orders
      ordergroup = group_order.ordergroup
      logger.debug("Send 'order finished' message to #{ordergroup.name}")
      # Determine users that want a notification message:
      users = ordergroup.users.reject{|u| u.settings["notify.orderFinished"] != '1'}
      unless users.empty?
        # Create user notification messages:
        Message.from_template(
          'order_finished',
          {:group => ordergroup, :order => self, :group_order => group_order},
          {:recipients_ids => users.collect(&:id), :subject => "Bestellung beendet: #{supplier.name}"}
        ).save!
      end
    end
  end

end
