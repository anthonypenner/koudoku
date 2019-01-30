module Koudoku::Subscription
  extend ActiveSupport::Concern

  included do

    # We don't store these one-time use tokens, but this is what Stripe provides
    # client-side after storing the credit card information.
    attr_accessor :credit_card_token

    belongs_to :plan

    # update details.
    before_save :processing!
    def processing!

      # if their package level has changed ..
      if changing_plans?

        prepare_for_plan_change

        # and a customer exists in stripe ..
        if stripe_id.present?

          # fetch the customer.
          customer = Stripe::Customer.retrieve(self.stripe_id)
          if self.credit_card_token.present?
            prepare_for_card_update

            customer.source = self.credit_card_token
            customer.save

            # update the last four based on this new card.
            self.last_four = customer.sources.retrieve(customer.default_source).last4
            self.expiry_month = customer.sources.retrieve(customer.default_source).exp_month
            self.expiry_year = customer.sources.retrieve(customer.default_source).exp_year
            finalize_card_update!
          end

          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_downgrade if downgrading?
            prepare_for_upgrade if upgrading?

            begin
              # update the package level with stripe.

              if self.coupon.present? && (self.coupon == '2MONTHSFREE' || self.coupon == 'TESTDRIVE')
                if self.coupon == '2MONTHSFREE'
                  customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate, trial_end: (Time.zone.now + 2.months).to_i)
                elsif self.coupon == 'TESTDRIVE'
                  customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate, trial_end: (Time.zone.now + 1.months).to_i)
                end
              else
                customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate, :coupon => self.coupon)
              end

            rescue Stripe::InvalidRequestError => card_error
              errors[:base] << card_error.message
              invalid_coupon
              return false
            end

            finalize_downgrade! if downgrading?
            finalize_upgrade! if upgrading?

          # if no plan has been selected.
          else

            prepare_for_cancelation

            # Remove the current pricing.
            self.current_price = nil

            # delete the subscription.
            customer.cancel_subscription

            finalize_cancelation!

          end

        # when customer DOES NOT exist in stripe ..
        else
          # if a new plan has been selected
          if self.plan.present?

            # Record the new plan pricing.
            self.current_price = self.plan.price

            prepare_for_new_subscription
            prepare_for_upgrade

            begin
              raise Koudoku::NilCardToken, "Possible javascript error" if credit_card_token.blank?
              customer_attributes = {
                description: subscription_owner_description,
                email: subscription_owner_email,
                source: credit_card_token # obtained with Stripe.js
              }

              # create a customer at that package level.
              customer = Stripe::Customer.create(customer_attributes)

              finalize_new_customer!(customer.id, plan.price)

              if self.coupon.present? && (self.coupon == '2MONTHSFREE' || self.coupon == 'TESTDRIVE')
                if self.coupon == '2MONTHSFREE'
                  customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate, trial_end: (Time.zone.now + 2.months).to_i)
                elsif self.coupon == 'TESTDRIVE'
                  customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate, trial_end: (Time.zone.now + 1.months).to_i)
                end
              else
                customer.update_subscription(:plan => self.plan.stripe_id, :prorate => Koudoku.prorate, :coupon => self.coupon)
              end

            rescue Stripe::InvalidRequestError => card_error
              errors[:base] << card_error.message
              invalid_coupon
              return false

            rescue Stripe::CardError => card_error
              errors[:base] << card_error.message
              card_was_declined
              return false

            rescue
              errors[:base] << 'Something went wrong on this page, please try refreshing and contact support if this error persists.'
              return false
            end

            # store the customer id.
            self.stripe_id = customer.id
            self.last_four = customer.sources.retrieve(customer.default_source).last4
            self.expiry_month = customer.sources.retrieve(customer.default_source).exp_month
            self.expiry_year = customer.sources.retrieve(customer.default_source).exp_year

            finalize_new_subscription!
            finalize_upgrade!

          else

            # This should never happen.

            self.plan_id = nil

            # Remove any plan pricing.
            self.current_price = nil

          end

        end

        finalize_plan_change!

      # if they're updating their credit card details.
      elsif self.credit_card_token.present?

        prepare_for_card_update

        # fetch the customer.
        customer = Stripe::Customer.retrieve(self.stripe_id)
        customer.source = self.credit_card_token
        customer.save

        # update the last four based on this new card.
        self.last_four = customer.sources.retrieve(customer.default_source).last4
        self.expiry_month = customer.sources.retrieve(customer.default_source).exp_month
        self.expiry_year = customer.sources.retrieve(customer.default_source).exp_year
        finalize_card_update!

      end
    end
  end


  def describe_difference(plan_to_describe)
    if plan.nil?
      if persisted?
        I18n.t('koudoku.plan_difference.upgrade')
      else
        if Koudoku.free_trial?
          I18n.t('koudoku.plan_difference.start_trial')
        else
          I18n.t('koudoku.plan_difference.upgrade')
        end
      end
    else
      if plan_to_describe.is_upgrade_from?(plan)
        I18n.t('koudoku.plan_difference.upgrade')
      else
        I18n.t('koudoku.plan_difference.downgrade')
      end
    end
  end

  # Set a Stripe coupon code that will be used when a new Stripe customer (a.k.a. Koudoku subscription)
  # is created
  def coupon_code=(new_code)
    @coupon_code = new_code
  end

  # Pretty sure this wouldn't conflict with anything someone would put in their model
  def subscription_owner
    # Return whatever we belong to.
    # If this object doesn't respond to 'name', please update owner_description.
    send Koudoku.subscriptions_owned_by
  end

  def subscription_owner=(owner)
    # e.g. @subscription.user = @owner
    send Koudoku.owner_assignment_sym, owner
  end

  def subscription_owner_description
    # assuming owner responds to name.
    # we should check for whether it responds to this or not.
    "#{subscription_owner.try(:name) || subscription_owner.try(:id)}"
  end

  def subscription_owner_email
    "#{subscription_owner.try(:email)}"
  end

  def changing_plans?
    plan_id_changed?
  end

  def downgrading?
    plan.present? and plan_id_was.present? and plan_id_was > self.plan_id
  end

  def upgrading?
    (plan_id_was.present? and plan_id_was < plan_id) or plan_id_was.nil?
  end

  # Template methods.
  def prepare_for_plan_change
  end

  def prepare_for_new_subscription
  end

  def prepare_for_upgrade
  end

  def prepare_for_downgrade
  end

  def prepare_for_cancelation
  end

  def prepare_for_card_update
  end

  def finalize_plan_change!
  end

  def finalize_new_subscription!
  end

  def finalize_new_customer!(customer_id, amount)
  end

  def finalize_upgrade!
  end

  def finalize_downgrade!
  end

  # Called from the cancel action in the subscriptiosn controller. Allows
  # you to tie into the cancel params from your app. In our use case, we let you select
  # which products you would like to keep within the free tier.
  def before_cancelation(request_params)
  end

  def finalize_cancelation!
  end

  def finalize_card_update!
  end

  def card_was_declined
  end

  # stripe web-hook callbacks.
  def payment_succeeded(amount)
  end

  def charge_failed
  end

  def charge_disputed
  end

  def invalid_coupon
  end

end
