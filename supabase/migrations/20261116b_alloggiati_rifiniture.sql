-- Bee&blu – rifiniture dopo i test con il servizio Test della Polizia (16/11/2026).
-- Sostituisce le versioni delle funzioni del file 20261116_alloggiati_schedine.sql.
-- Risultati dei test reali: apostrofo ammesso, trattino NO; arrivo accettato solo oggi o ieri.

insert into public.luoghi_alias (alias, descrizione) values
 ('MILAN','MILANO'),('ROME','ROMA'),('FLORENCE','FIRENZE'),('VENICE','VENEZIA'),('NAPLES','NAPOLI'),('TURIN','TORINO'),('GENOA','GENOVA'),
 ('PADUA','PADOVA'),('MANTUA','MANTOVA'),('SYRACUSE','SIRACUSA'),('BOZEN','BOLZANO'),('LAQUILA','L''AQUILA'),('L AQUILA','L''AQUILA'),('MERAN','MERANO'),('BRIXEN','BRESSANONE'),
 ('BRASIL','BRASILE'),('MAGYARORSZAG','UNGHERIA'),('ELLADA','GRECIA'),('SVERIGE','SVEZIA'),('NORGE','NORVEGIA'),('DANMARK','DANIMARCA'),('SUOMI','FINLANDIA'),('HRVATSKA','CROAZIA'),('CESKO','REPUBBLICA CECA'),('ROSSIYA','FEDERAZIONE RUSSA'),('NIPPON','GIAPPONE'),('ZHONGGUO','CINA'),
 ('NORTH KOREA','COREA DEL NORD'),('KOREA NORTH','COREA DEL NORD'),('DPRK','COREA DEL NORD'),('KOREA SOUTH','COREA DEL SUD'),
 ('SOUTH SUDAN','SUD SUDAN'),('DR CONGO','REPUBBLICA DEMOCRATICA DEL CONGO'),('DRC','REPUBBLICA DEMOCRATICA DEL CONGO'),('DEMOCRATIC REPUBLIC OF THE CONGO','REPUBBLICA DEMOCRATICA DEL CONGO'),
 ('PAPUA NEW GUINEA','PAPUASIA-N.GUINEA'),('EQUATORIAL GUINEA','GUINEA EQUATORIALE'),('IVORY COAST','COSTA D''AVORIO'),('COTE D IVOIRE','COSTA D''AVORIO')
on conflict (alias) do update set descrizione = excluded.descrizione;

-- Nomi Alloggiati: solo lettere, spazi e apostrofo
create or replace function public.testo_schedina(t text, lunghezza int)
returns text language sql immutable set search_path = public, extensions as $$
  select rpad(left(trim(regexp_replace(regexp_replace(upper(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, ''))), '[^A-Z'']', ' ', 'g'), '\s+', ' ', 'g')), lunghezza), lunghezza, ' ')
$$;

-- Toglie "Comune di", "Questura di"… dai luoghi di rilascio
create or replace function public.pulisci_ente(t text) returns text
language sql immutable set search_path = public, extensions as $$
  select regexp_replace(coalesce(t, ''), '^\s*(comune|questura|prefettura|municipio|consolato|ambasciata|ufficio|ministero)\s+(di|de|del|della|dell''|d'')\s*', '', 'i')
$$;

-- Candidati per la somiglianza: nomi ufficiali + alias inglesi
create or replace view public.stati_candidati with (security_invoker = true) as
  select l.codice, l.descrizione, public.norm_luogo(l.descrizione) nome from public.luoghi l where l.provincia = 'ES' and not l.cessato
  union all
  select l.codice, l.descrizione, a.alias from public.luoghi_alias a join public.luoghi l on l.descrizione = a.descrizione and l.provincia = 'ES' and not l.cessato;

-- Stato: alias -> esatto -> inizio univoco -> somiglianza solo se ≥0.55 e staccata di 0.15 dal secondo; altrimenti "incerto" (da correggere)
create or replace function public.risolvi_stato(t text)
returns table (codice text, descrizione text, metodo text)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
declare n text := public.norm_luogo(t); s1 record; s2 real;
begin
  if n is null then return; end if;
  return query select l.codice, l.descrizione, 'alias'::text from public.luoghi_alias a
    join public.luoghi l on l.descrizione = a.descrizione and l.provincia = 'ES' and not l.cessato
    where a.alias = n limit 1;
  if found then return; end if;
  return query select l.codice, l.descrizione, 'esatto'::text from public.luoghi l
    where l.provincia = 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n limit 1;
  if found then return; end if;
  return query select l.codice, l.descrizione, 'inizio'::text from public.luoghi l
    where l.provincia = 'ES' and not l.cessato and length(n) >= 4 and public.norm_luogo(l.descrizione) like n || ' %'
    and (select count(*) from public.luoghi x where x.provincia = 'ES' and not x.cessato and public.norm_luogo(x.descrizione) like n || ' %') = 1;
  if found then return; end if;
  select c.codice, c.descrizione, max(extensions.similarity(c.nome, n)) sim into s1
    from public.stati_candidati c group by c.codice, c.descrizione order by 3 desc limit 1;
  select max(extensions.similarity(c.nome, n)) into s2
    from public.stati_candidati c where c.codice <> s1.codice group by c.codice order by 1 desc limit 1;
  if s1.sim >= 0.55 and s1.sim - coalesce(s2, 0) >= 0.15 then
    return query select s1.codice, s1.descrizione, ('simile ' || round(s1.sim::numeric, 2))::text;
  elsif s1.sim >= 0.3 then
    return query select null::text, s1.descrizione, 'incerto'::text;
  end if;
end $$;

-- Comune: accetta "Milano", "Milano (MI)", "Comune di Milano", "Milan". Omonimi senza provincia -> "ambiguo".
create or replace function public.risolvi_comune(t text)
returns table (codice text, descrizione text, provincia text, metodo text)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
declare
  raw text := public.pulisci_ente(t);
  prov text := upper(substring(raw from '\(?\m([A-Za-z]{2})\M\)?\s*$'));
  n text;
  quanti int; s1 record; s2 real;
begin
  n := public.norm_luogo(raw);
  if n is null then return; end if;
  if prov is not null and exists (select 1 from public.luoghi x where x.provincia = prov and x.provincia <> 'ES') and length(n) > 3 then
    n := trim(regexp_replace(n, '\s' || prov || '$', ''));
  else
    prov := null;
  end if;
  select a.descrizione into raw from public.luoghi_alias a where a.alias = n
    and exists (select 1 from public.luoghi l where l.descrizione = a.descrizione and l.provincia <> 'ES' and not l.cessato);
  if found then n := public.norm_luogo(raw); end if;
  select count(*) into quanti from public.luoghi l where l.provincia <> 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n;
  if quanti = 1 or (quanti > 1 and prov is not null) then
    return query select l.codice, l.descrizione, l.provincia, 'esatto'::text from public.luoghi l
      where l.provincia <> 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n and (prov is null or l.provincia = prov) limit 1;
    if found then return; end if;
  end if;
  if quanti > 1 then
    return query select null::text, string_agg(l.descrizione || ' (' || l.provincia || ')', ', '), null::text, 'ambiguo'::text
      from public.luoghi l where l.provincia <> 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n;
    return;
  end if;
  select l.codice, l.descrizione, l.provincia, extensions.similarity(public.norm_luogo(l.descrizione), n) sim into s1
    from public.luoghi l where l.provincia <> 'ES' and not l.cessato and (prov is null or l.provincia = prov)
    and public.norm_luogo(l.descrizione) operator(extensions.%) n
    order by 4 desc limit 1;
  if s1.codice is null then return; end if;
  select extensions.similarity(public.norm_luogo(l.descrizione), n) into s2
    from public.luoghi l where l.provincia <> 'ES' and not l.cessato and (prov is null or l.provincia = prov)
    and l.codice <> s1.codice and public.norm_luogo(l.descrizione) operator(extensions.%) n order by 1 desc limit 1;
  if s1.sim >= 0.75 and s1.sim - coalesce(s2, 0) >= 0.1 then
    return query select s1.codice, s1.descrizione, s1.provincia, ('simile ' || round(s1.sim::numeric, 2))::text;
  else
    return query select null::text, s1.descrizione || ' (' || s1.provincia || ')', null::text, 'incerto'::text;
  end if;
end $$;

create or replace function public.schedine_prenotazione(p_id uuid)
returns table (ordine int, record text, problemi text[], dettagli jsonb)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
declare
  p record; o record; n_ospiti int; tipo text;
  sn_cod text; sn_nome text; sn_met text;
  cn_cod text; cn_nome text; cn_prov text; cn_met text;
  ct_cod text; ct_nome text; ct_met text;
  rl_cod text; rl_nome text; rl_met text;
  probs text[]; nascita_it boolean; rec text; giorni int;
begin
  select * into p from public.prenotazioni x where x.id = p_id;
  if not found then return; end if;
  select count(*) into n_ospiti from public.ospiti x where x.prenotazione_id = p_id;
  giorni := least(30, greatest(1, p.notti));

  for o in select * from public.ospiti x where x.prenotazione_id = p_id order by x.ordine loop
    probs := '{}';
    sn_cod := null; sn_nome := null; sn_met := null; cn_cod := null; cn_nome := null; cn_prov := null; cn_met := null;
    ct_cod := null; ct_nome := null; ct_met := null; rl_cod := null; rl_nome := null; rl_met := null;
    tipo := case when n_ospiti = 1 then '16'
                 when o.ordine = 0 then case when p.tipo_gruppo = 'gruppo' then '18' else '17' end
                 else case when p.tipo_gruppo = 'gruppo' then '20' else '19' end end;

    select r.codice, r.descrizione, r.metodo into sn_cod, sn_nome, sn_met from public.risolvi_stato(o.stato_nascita) r;
    if sn_cod is null then probs := probs || ('stato di nascita ' || case when sn_met = 'incerto' then 'incerto (forse ' || sn_nome || ')' else 'non riconosciuto' end || ': ' || coalesce(o.stato_nascita, '-')); end if;
    nascita_it := coalesce(sn_cod = '100000100', false);
    if nascita_it then
      select r.codice, r.descrizione, r.provincia, r.metodo into cn_cod, cn_nome, cn_prov, cn_met from public.risolvi_comune(o.comune_nascita) r;
      if cn_cod is null then probs := probs || ('comune di nascita ' || coalesce(cn_met, 'non riconosciuto') || ': ' || coalesce(o.comune_nascita, '-') || coalesce(' -> ' || cn_nome, '')); end if;
    end if;
    select r.codice, r.descrizione, r.metodo into ct_cod, ct_nome, ct_met from public.risolvi_stato(o.cittadinanza) r;
    if ct_cod is null then probs := probs || ('cittadinanza ' || case when ct_met = 'incerto' then 'incerta (forse ' || ct_nome || ')' else 'non riconosciuta' end || ': ' || coalesce(o.cittadinanza, '-')); end if;
    if o.data_nascita is null then probs := probs || 'data di nascita mancante'::text;
    elsif o.data_nascita > p.data_arrivo then probs := probs || 'data di nascita nel futuro'::text; end if;
    if p.data_arrivo not in ((now() at time zone 'Europe/Rome')::date, (now() at time zone 'Europe/Rome')::date - 1) then
      probs := probs || ('la Questura accetta solo arrivi di oggi o ieri (arrivo: ' || to_char(p.data_arrivo, 'DD/MM/YYYY') || ')');
    end if;
    if coalesce(o.sesso, '') not in ('M', 'F') then probs := probs || 'sesso mancante'::text; end if;
    if public.norm_luogo(o.cognome) is null or public.norm_luogo(o.nome) is null then probs := probs || 'nome o cognome mancante'::text; end if;

    if tipo in ('16', '17', '18') then
      if not exists (select 1 from public.tipi_documento d where d.codice = o.tipo_documento) then probs := probs || ('tipo documento non valido: ' || coalesce(o.tipo_documento, '-')); end if;
      if public.norm_luogo(o.numero_documento) is null then probs := probs || 'numero documento mancante'::text; end if;
      select r.codice, r.descrizione, r.metodo into rl_cod, rl_nome, rl_met from public.risolvi_stato(o.luogo_rilascio) r where r.metodo in ('alias', 'esatto');
      if rl_cod is null then
        select r.codice, r.descrizione, r.metodo into rl_cod, rl_nome, rl_met from public.risolvi_comune(o.luogo_rilascio) r;
        if rl_cod is null then
          select r.codice, r.descrizione, r.metodo into rl_cod, rl_nome, rl_met from public.risolvi_stato(public.pulisci_ente(o.luogo_rilascio)) r where r.codice is not null;
          if rl_cod is null and public.norm_luogo(o.luogo_rilascio) is not null and coalesce(ct_cod, '100000100') <> '100000100' then
            -- documento straniero con una città estera (es. "Berlin"): vale lo Stato di cittadinanza
            rl_cod := ct_cod; rl_nome := ct_nome; rl_met := 'da cittadinanza';
          end if;
          if rl_cod is null then probs := probs || ('luogo di rilascio non riconosciuto: ' || coalesce(o.luogo_rilascio, '-')); end if;
        end if;
      end if;
    end if;

    rec := tipo
      || to_char(p.data_arrivo, 'DD/MM/YYYY')
      || lpad(giorni::text, 2, '0')
      || public.testo_schedina(o.cognome, 50)
      || public.testo_schedina(o.nome, 30)
      || case o.sesso when 'M' then '1' when 'F' then '2' else ' ' end
      || coalesce(to_char(o.data_nascita, 'DD/MM/YYYY'), '          ')
      || rpad(case when nascita_it then coalesce(cn_cod, '') else '' end, 9)
      || rpad(case when nascita_it then coalesce(cn_prov, '') else '' end, 2)
      || rpad(coalesce(sn_cod, ''), 9)
      || rpad(coalesce(ct_cod, ''), 9)
      || case when tipo in ('16', '17', '18') then
           rpad(coalesce(o.tipo_documento, ''), 5)
           || rpad(left(upper(regexp_replace(coalesce(o.numero_documento, ''), '[^A-Za-z0-9]', '', 'g')), 20), 20)
           || rpad(coalesce(rl_cod, ''), 9)
         else repeat(' ', 34) end;

    if length(rec) <> 168 then probs := probs || ('lunghezza record ' || length(rec)); end if;

    ordine := o.ordine; record := rec; problemi := probs;
    dettagli := jsonb_build_object(
      'tipo', tipo,
      'stato_nascita', jsonb_build_object('testo', o.stato_nascita, 'codice', sn_cod, 'nome', sn_nome, 'metodo', sn_met),
      'comune_nascita', case when nascita_it then jsonb_build_object('testo', o.comune_nascita, 'codice', cn_cod, 'nome', cn_nome, 'prov', cn_prov, 'metodo', cn_met) end,
      'cittadinanza', jsonb_build_object('testo', o.cittadinanza, 'codice', ct_cod, 'nome', ct_nome, 'metodo', ct_met),
      'rilascio', case when tipo in ('16', '17', '18') then jsonb_build_object('testo', o.luogo_rilascio, 'codice', rl_cod, 'nome', rl_nome, 'metodo', rl_met) end);
    return next;
  end loop;
end $$;

revoke all on function public.schedine_prenotazione(uuid), public.risolvi_stato(text), public.risolvi_comune(text) from public, anon, authenticated;
revoke all on public.stati_candidati from anon, authenticated;
grant execute on function public.schedine_prenotazione(uuid), public.risolvi_stato(text), public.risolvi_comune(text),
  public.testo_schedina(text, int), public.norm_luogo(text), public.pulisci_ente(text) to service_role;
grant select on public.stati_candidati, public.luoghi_alias to service_role;
