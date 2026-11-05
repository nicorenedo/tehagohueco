-- Correo único "¿Qué tal fue tu viaje?" (05-11-2026), firmado por Nico, para pedir una opinión breve a un medio.
-- Solo a quien tiene activados los avisos de sus viajes (lo comprueba avisos.claim, como el resto de tipos "viajes").
-- Las pruebas (payload test=true) solo llegan a las direcciones de avisos.config.test_emails.
alter table avisos.outbox drop constraint outbox_kind_check;
alter table avisos.outbox add constraint outbox_kind_check check (kind = any (array['cancelado','cambio','quitado','pasajeros','confirmar','sin_confirmar','alerta','gracias','prensa']));
-- En avisos.claim se añadió a la condición 'sin permiso':
--   and not (o.kind = 'prensa' and o.payload ->> 'test' = 'true' and lower(v_email) = any (cfg.test_emails))
