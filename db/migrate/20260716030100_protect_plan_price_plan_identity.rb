class ProtectPlanPricePlanIdentity < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION public.protect_plan_price_plan_identity()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, public
      AS $function$
      BEGIN
        IF NEW.plan_id IS DISTINCT FROM OLD.plan_id THEN
          RAISE EXCEPTION 'plan price plan identity is immutable'
            USING ERRCODE = '23514',
              CONSTRAINT = 'plan_prices_plan_identity_immutable',
              TABLE = 'plan_prices';
        END IF;

        RETURN NEW;
      END;
      $function$;

      CREATE TRIGGER plan_prices_plan_identity_is_immutable
      BEFORE UPDATE OF plan_id ON plan_prices
      FOR EACH ROW
      EXECUTE FUNCTION public.protect_plan_price_plan_identity();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS plan_prices_plan_identity_is_immutable
        ON plan_prices;
      DROP FUNCTION IF EXISTS public.protect_plan_price_plan_identity();
    SQL
  end
end
