# Jabba-Terminal — Specifica v2.4

Protocollo **Jabba** (match maker-contro-maker) e requisiti del terminale.

> Nota di implementazione: `match` è una parola riservata in Solidity. La funzione di scambio si chiama `matchOrders`; in questa specifica "match" indica l'operazione.

## 1. Scopo e principi

Jabba v2.4 è un exchange P2P su Robinhood Chain (chain ID 4663): ogni scambio è l'incrocio di due ordini firmati da due utenti. Non esistono taker, pool, market maker né servizi online necessari all'esecuzione.

- **Due funzioni pubbliche:** `matchOrders` esegue gli scambi, `post` pubblica gli ordini.
- **Zero custodia, nessun owner, un solo slot di storage (la fee):** i token passano da maker a maker dentro Permit2; il contratto non detiene mai saldi.
- **Tutto-o-niente:** ogni ordine si esegue per intero o non si esegue.
- **Fee fissa in ETH, modificabile solo dal tesoriere:** separata dagli importi scambiati, identica per qualsiasi coppia di ERC-20.
- **Nessuna chiave del servizio negli scambi:** l'unica firma verificata è quella dei maker.
- **Deterministico:** stesso input, stesso esito; nessun oracolo, prezzo, blocco o casualità.
- **Libro ordini on-chain:** gli ordini aperti sono i log dell'evento `OrderPosted`, ricostruibili da chiunque.

## 2. Modello

Ogni ordine è una firma Permit2 del maker, pubblicata con `post`; chi chiude una coppia di ordini opposti invia `matchOrders` e paga la fee.

- **Ordine:** il maker firma `PermitWitnessTransferFrom` con `permitted = (sellToken, sellAmount)`, `spender = Jabba`, `nonce`, `deadline` e witness `Order(buyToken, buyAmount)`. Significa: cedo esattamente `sellAmount` di X e voglio almeno `buyAmount` di Y. Qualsiasi coppia di ERC-20 è ammessa.
- **Pubblicazione:** il maker, o chiunque abbia la firma, chiama `post`, che emette `OrderPosted` con l'ordine completo e la firma.
- **Submitter:** chiunque invii `matchOrders`. Di norma è il secondo utente, che vede un ordine aperto, firma l'ordine complementare e chiude la coppia; un terzo può anche eseguire due ordini pubblicati che si incrociano.
- **Surplus:** ogni maker cede tutto ciò che ha firmato e riceve tutto ciò che la controparte cede; l'eccedenza di un incrocio va alla controparte, il contratto non trattiene nulla.
- **Cancellazione:** il maker chiama direttamente `Permit2.invalidateUnorderedNonces`, oppure lascia scadere la `deadline`.
- **ETH negli scambi:** solo tramite WETH; `msg.value` è riservato alla fee.

**Fee policy (normativa).** Il submitter paga in `msg.value` esattamente `fee` wei per ogni match; il contratto la inoltra per intero a `TREASURY`. `fee` è un solo valore in storage, iniziale 0,00005 ETH (50 000 000 000 000 wei), e non dipende da token, importi o prezzi. Solo `TREASURY` può cambiarla con `setFee`. Poiché `matchOrders` richiede `msg.value == fee` esatto, un cambio di fee durante una transazione in volo produce solo un revert: nessun utente paga mai più di quanto ha inviato. `post` non paga fee.

**Perimetro dei token (normativo).** Il contratto accetta qualsiasi ERC-20, ma le garanzie esatte valgono solo per i *token conformi*: un `transferFrom` di `x` sposta esattamente `x` dal mittente al destinatario, senza fee, senza rebasing durante la transazione e senza callback verso terzi. Per ogni altro token il contratto garantisce solo il pavimento: ogni maker riceve almeno quanto la controparte ha ceduto, altrimenti revert. Token fee-on-transfer vanno sempre in revert; token rebasing o malevoli possono passare, fuori dalle garanzie esatte.

**Conformità corrente, non permanente.** La conformità è una proprietà dell'ERC-20, non di Jabba. Gli stock token di Robinhood Chain sono conformi oggi, ma sono proxy aggiornabili dall'emittente, con pausa per token e globale e una blocklist condivisa. Un token in pausa o un maker bloccato fa fallire `transferFrom` e quindi l'intero match, senza consumare nonce. Jabba non contiene logica specifica per gli stock token.

## 3. Strutture dati e tipi EIP-712

Un solo tipo firmato: l'ordine del maker, nel dominio Permit2. Jabba non ha un proprio dominio EIP-712 e non verifica firme proprie.

**Order (witness Permit2)**

```
Order(address buyToken,uint256 buyAmount)
```

Witness type string passata a Permit2, con i tipi in ordine alfabetico come richiede EIP-712:

```
Order witness)Order(address buyToken,uint256 buyAmount)TokenPermissions(address token,uint256 amount)
```

**orderHash (identificatore, normativo)**

```
ORDER_TYPEHASH             = keccak256("Order(address buyToken,uint256 buyAmount)")
TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)")
PERMIT_WITNESS_TYPEHASH    = keccak256("PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline," ++ WITNESS_TYPE_STRING)

orderWitnessHash        = keccak256(abi.encode(ORDER_TYPEHASH, buyToken, buyAmount))
tokenPermissionsHash    = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, sellToken, sellAmount))
permitWitnessStructHash = keccak256(abi.encode(PERMIT_WITNESS_TYPEHASH, tokenPermissionsHash, address(this), nonce, deadline, orderWitnessHash))
orderHash               = keccak256(abi.encode(maker, permitWitnessStructHash))
```

`orderHash` include il maker perché il typed data di Permit2 non contiene l'owner. Serve solo come identificatore negli eventi `OrderPosted` e `Matched`; nessuna autorizzazione dipende da esso.

**Side (input di ciascun lato di `matchOrders` e di `post`)**

| Campo | Tipo | Nota |
|---|---|---|
| permit | PermitTransferFrom | sellToken, sellAmount, nonce, deadline |
| maker | address | proprietario dei token, firmatario |
| order | Order | buyToken, buyAmount |
| sig | bytes | 65 oppure 64 byte (EIP-2098), verificata da Permit2 al match |

Nessun campo indica un destinatario: i destinatari sono derivati dal contratto.

**Eventi**

```
event OrderPosted(bytes32 orderHash, address indexed maker, address indexed sellToken, address indexed buyToken,
                  uint256 sellAmount, uint256 buyAmount, uint256 nonce, uint256 deadline, bytes sig);
event Matched(bytes32 orderHashA, bytes32 orderHashB, address indexed submitter, uint256 fee);
event FeeChanged(uint256 oldFee, uint256 newFee);
```

In `OrderPosted` maker e token sono indicizzati, così il terminale filtra il libro per token direttamente dai log.

**Costanti e stato**

| Nome | Tipo | Valore |
|---|---|---|
| PERMIT2 | constant | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| TREASURY | immutable | multisig, fissato al deploy; unico autorizzato a `setFee` |
| fee | storage (1 slot) | iniziale 50 000 000 000 000 wei (0,00005 ETH) |

## 4. Funzione matchOrders

`matchOrders(Side a, Side b) payable` esegue entrambi gli ordini per intero in una transazione, oppure fa revert senza effetti.

**Precondizioni** (revert con errore dedicato se una fallisce)

1. `a.maker != 0`, `b.maker != 0`, `a.maker != b.maker`.
2. Token opposti: `a.sellToken == b.buyToken`, `b.sellToken == a.buyToken`, `a.sellToken != a.buyToken`.
3. Importi non nulli: `sellAmount > 0` e `buyAmount > 0` su entrambi i lati.
4. Prezzi e taglie incrociati: `a.sellAmount >= b.buyAmount` e `b.sellAmount >= a.buyAmount`.
5. Fee: `msg.value == fee` (valore corrente in storage).

**Sequenza**

1. Imposta il lock in transient storage (EIP-1153); revert se già attivo.
2. Legge i saldi di partenza: `a.buyToken` di A e `b.buyToken` di B.
3. Permit2 `permitWitnessTransferFrom` per il lato A: owner `a.maker`, `to = b.maker`, `requestedAmount = a.sellAmount`, witness `orderWitnessHash` di A.
4. Permit2 `permitWitnessTransferFrom` per il lato B: owner `b.maker`, `to = a.maker`, `requestedAmount = b.sellAmount`, witness `orderWitnessHash` di B.
5. Verifica ricezione: il saldo di A in `a.buyToken` è cresciuto di almeno `b.sellAmount`, quello di B in `b.buyToken` di almeno `a.sellAmount`; altrimenti revert. Con il lock attivo nessun altro accredito è possibile, quindi per un token conforme la crescita è esatta.
6. Inoltra `msg.value` a `TREASURY` se diverso da zero; revert se il trasferimento fallisce.
7. Emette `Matched(orderHashA, orderHashB, msg.sender, fee)` e rilascia il lock.

I destinatari (`to`) sono derivati esclusivamente dai maker: `b.maker` per il lato A, `a.maker` per il lato B. Nessun input li controlla.

**Postcondizioni**

- Entrambi i nonce sono consumati nella bitmap di Permit2.
- Saldo token e saldo ETH di Jabba a zero.
- Nessuna scrittura nello storage persistente di Jabba.

Ogni revert (Permit2 incluso: firma, nonce, deadline, saldo, approve mancanti, token in pausa, maker in blocklist) annulla l'intera transazione; non esiste esecuzione parziale e nessun nonce resta consumato.

## 5. Funzione post

`post(Side s)` pubblica un ordine nel libro on-chain.

1. Revert se `s.maker == 0`, se `s.sellToken == s.buyToken` o se un importo è zero.
2. Calcola `orderHash` secondo la §3.
3. Emette `OrderPosted` con tutti i campi dell'ordine e la firma.

`post` non verifica firma, nonce, saldi né scadenza: costerebbe gas a ogni pubblicazione e Permit2 li verifica comunque al match. Non scrive storage, non sposta fondi, non è `payable` ed è chiamabile da chiunque. Un ordine pubblicato non crea alcun diritto: diventa eseguibile solo se la firma è valida quando qualcuno lo usa in `matchOrders`.

## 6. Funzione setFee

`setFee(uint256 newFee)` è l'unica funzione amministrativa e tocca solo la fee.

1. Revert se `msg.sender != TREASURY`.
2. Scrive `fee = newFee` ed emette `FeeChanged(oldFee, newFee)`.

`setFee` non può toccare token, nonce, ordini o destinatari e non può pausare `matchOrders` né `post`. `TREASURY` è immutable: il ruolo non si trasferisce. `newFee = 0` è ammesso (scambi senza fee).

## 7. Invarianti

| ID | Proprietà |
|---|---|
| I1 | Dopo un match riuscito il saldo di A in `a.buyToken` è cresciuto di almeno `b.sellAmount` e quello di B in `b.buyToken` di almeno `a.sellAmount`; per i token conformi la crescita è esatta. Per le precondizioni queste quantità sono ≥ `a.buyAmount` e ≥ `b.buyAmount` |
| I2 | Per i token conformi, ogni maker cede esattamente il `sellAmount` firmato. Per i token non conformi questa proprietà non è garantita; `matchOrders` garantisce comunque che ogni maker riceva almeno quanto la controparte ha ceduto, altrimenti l'intera transazione fa revert |
| I3 | Ogni ordine si esegue al massimo una volta e per intero; il consumo del nonce avviene nello storage di Permit2 |
| I4 | L'unico storage persistente di Jabba è `fee`, scritto solo da `setFee`; ogni chiamata chiude con saldi token ed ETH del contratto a zero |
| I5 | `msg.value` di `matchOrders` è uguale alla `fee` corrente ed è inoltrato per intero a `TREASURY` |
| I6 | Per i token conformi, la somma dei saldi dei due maker è conservata per ogni token |
| I7 | Il destinatario di ogni gamba è la controparte, fissato dal contratto e non controllabile dal submitter |
| I8 | `post` non modifica alcuno stato e non sposta alcun valore: il suo unico effetto è l'evento |

## 8. Controlli di sicurezza on-chain

| Rischio | Evidenza | Controllo | Livello |
|---|---|---|---|
| Permit che non vincola il destinatario | [audit porting Permit2, 2026](https://github.com/Frankcastleauditor/Solana-Audit-Arena/issues/249) | Entrambe le gambe con `permitWitnessTransferFrom`; `to` derivato dai maker (I7) | Contratto |
| Firma non legata al digest atteso | [audit porting Permit2, 2026](https://github.com/Frankcastleauditor/Solana-Audit-Arena/issues/246) | Firme verificate solo da Permit2 su typed data EIP-712 standard; test incrociato con firmatore di riferimento | Contratto + test |
| Owner zero | [audit porting Permit2, 2026](https://github.com/Frankcastleauditor/Solana-Audit-Arena/issues/253) | Revert se `maker == 0` in `matchOrders` e in `post` | Contratto |
| Deadline non applicata | [audit porting Permit2, 2026](https://github.com/Frankcastleauditor/Solana-Audit-Arena/issues/238) | Deadline degli ordini applicata da Permit2 | Contratto |
| Chiamate arbitrarie nel settlement | [CoW, incidente hook 2023](https://cryptogloss.io/glossary/cowswap/) | Nessuna callback o hook; chiamate esterne solo a Permit2, `balanceOf` e `TREASURY` | Contratto |
| Rientro da token malevolo che falsa i delta | analisi interna | Lock in transient storage (EIP-1153) | Contratto |
| Token fee-on-transfer o non conformi | [UniswapX, disclaimer FoT](https://github.com/Uniswap/UniswapX) | Verifica di ricezione su entrambe le gambe (I1, I2) | Contratto |
| Token in pausa o maker in blocklist | [analisi on-chain stock token](https://xroot.dev/blog/robinhood-chain-read-directly) | `transferFrom` fallisce, revert atomico, nessun nonce consumato | Contratto (per costruzione) |
| Maker con codice (contratto o EOA delegato 7702) | sorgente Permit2 `SignatureVerification` | Il contratto non assume EOA: la validità della firma è quella decisa da Permit2, ERC-1271 incluso | Contratto |
| Fee cambiata durante transazioni in volo | — | `fee` modificabile solo da `TREASURY`; `msg.value` esatto, quindi un cambio in volo produce solo revert | Contratto |
| Spam di ordini falsi nel libro | analisi interna | `post` costa gas e non crea diritti; ordini non validi filtrati dal terminale e falliscono al match | Contratto + terminale |
| Tesoriere che rifiuta ETH | — | `TREASURY` è un multisig; se rifiuta ETH il match fa revert | Deploy |

## 9. Requisiti del terminale (non verificabili on-chain)

Policy del client: riducono il rischio per l'utente ma non sono proprietà di sicurezza del contratto e nessun invariante dipende da esse.

**Distribuzione e connessione**

- File HTML statico, ospitabile ovunque (GitHub Pages, IPFS, locale), senza backend.
- Connessione wallet tramite EIP-6963, con `window.ethereum` come fallback; richiesta di passaggio a chain 4663 e aggiunta della rete se assente.
- Tutte le firme passano dal wallet con `eth_signTypedData_v4`.

**Libro ordini**

- Un solo libro con tutte le coppie, ricostruito dai log `OrderPosted`, filtrabile per token, maker e hash.
- Un ordine è mostrato come eseguibile solo se: la firma si recupera sul maker (o è valida via ERC-1271), il nonce non è usato in Permit2, la `deadline` non è passata, saldo e approve del maker verso Permit2 bastano.
- Gli incroci eseguibili tra ordini pubblicati si rilevano applicando esattamente le precondizioni di `matchOrders`: prezzi e taglie insieme.

**Protezioni per l'utente**

| Requisito | Motivo |
|---|---|
| Legge lo stato di pausa del token e del registro e `isBlocked` per entrambi i maker; segna come non eseguibili gli ordini coinvolti | Pausa e blocklist degli stock token fanno fallire il match |
| Segnala `oraclePaused()` come corporate action in corso, solo come informazione | Il match resta tecnicamente eseguibile; il rischio è sul valore in azioni |
| Rileva il prefisso `0xef0100` (EOA delegato 7702) e segnala o limita gli ordini da delegate non riconosciuti | Con codice presente Permit2 verifica via ERC-1271; [DelegProof](https://eprint.iacr.org/2026/2060) documenta attacchi di sostituzione ERC-1271 |
| Typed data leggibili; spender sempre e solo Jabba | Phishing di firme Permit2 ([guida 2026](https://eco.com/support/en/articles/12005545-what-is-permit2-a-2026-guide-to-token-approvals)) |
| Approve a Permit2 limitati all'importo dell'ordine | Riduce l'esposizione a firme future malevole |
| Deadline corte sugli ordini (5 min – 4 h) | Limita la finestra di validità delle firme |
| Legge la `fee` corrente e simula `matchOrders` con `eth_call` subito prima dell'invio | Evita revert pagati nella corsa FCFS o dopo un cambio di fee |
| Mostra quantità degli stock token con `balanceOfUI()` e firma in unità raw | Moltiplicatore ERC-8056 |
| Rifiuta ordini con `deadline` oltre `effectiveAt()` se `newUIMultiplier()` differisce dal corrente | Il valore in azioni cambierebbe durante la validità dell'ordine |
| Tratta come non eseguito un match non incluso in tempi brevi e ne verifica i nonce | Screening al sequencer degli indirizzi sanzionati |
| Propone l'ordine complementare esatto quando si chiude un ordine | Il tutto-o-niente richiede taglie compatibili |

## 10. Ambiente: Robinhood Chain e stock token

**Chain**

- Arbitrum Nitro su ArbOS 61, chain ID 4663, gas in ETH, EVM a livello Fusaka.
- `block.number` restituisce una stima del blocco L1 e `prevrandao` è costante: la specifica usa solo `block.timestamp`.
- Ordinamento first-come, first-served al sequencer, senza priority gas auction.
- Screening al sequencer: le transazioni che coinvolgono indirizzi sanzionati non vengono incluse.
- Permit2 all'indirizzo canonico. USDG non supporta EIP-2612.

**Stock token**

- ERC-20 a 18 decimali, non rebasing, dietro un proxy aggiornabile dall'emittente.
- Moltiplicatore ERC-8056: cambia la rappresentazione, non i saldi raw; ordini e settlement operano in unità raw.
- Pausa per token e pausa globale tramite un registro condiviso; lo stesso registro espone `isBlocked`, una blocklist valida su tutti gli stock token. Secondo l'analisi citata, oggi i flag sono spenti e il moltiplicatore è 1e18.
- Durante una corporate action l'emittente mette in pausa il feed Chainlink con `oraclePaused()`.

**Build:** solc 0.8.35 o successivo (il repository usa 0.8.37), target `osaka`.

Fonti: [Differences from Ethereum](https://docs.robinhood.com/chain/differences-from-ethereum), [Building with Stock Tokens](https://docs.robinhood.com/chain/building-with-stock-tokens/), [Run a full node](https://docs.robinhood.com/chain/run-a-full-node/), [analisi on-chain stock token](https://xroot.dev/blog/robinhood-chain-read-directly), [Chainlink, feed Robinhood](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood).

## 11. Fuori scope e limiti accettati

**Escluso:** fill parziali, esecuzione in batch, modalità relayer/gasless, ETH nativo negli scambi, prezzi a decadimento, fee variabili per token o a livelli, quote firmate dal servizio, oracoli, tetto alla fee, upgradability, owner, pausa, verifica on-chain degli ordini in `post`, logica specifica per gli stock token.

**Limiti accettati**

- **Taglie compatibili:** due ordini si incrociano solo se le quantità lo permettono.
- **Fee uguale per ogni match:** micro-scambi e grandi scambi pagano la stessa `fee`.
- **Fiducia limitata nel tesoriere:** può impostare qualsiasi fee, anche così alta da fermare di fatto gli scambi; non può toccare fondi o ordini, e nessun utente paga più di quanto invia.
- **Poteri dell'emittente degli stock token:** può sospendere tutti gli scambi su quei token o escludere singoli indirizzi, senza alcun intervento di Jabba.
- **Costo di pubblicazione:** `post` costa gas al maker, minimo su L2 ma non zero.
- **Firme pubbliche:** chi pubblica rende la firma leggibile on-chain, necessario perché altri chiudano l'ordine.
- **Corsa FCFS** tra submitter sullo stesso ordine; il perdente paga solo il gas del revert.

Nessuna domanda aperta di specifica. Resta la verifica empirica dello stato corrente degli stock token (§12, punto 9).

## 12. Piano di verifica e deploy

1. **Test unitari e fuzz** (Foundry) contro il vero Permit2, usando l'utility precompilata `DeployPermit2`. Fatto: `test/Jabba.t.sol`.
2. **Test della fee:** `msg.value` diverso dalla fee corrente fa revert; `setFee` da un indirizzo diverso da `TREASURY` fa revert; un cambio di fee fra firma e invio produce solo revert, senza addebiti; tesoriere che rifiuta ETH fa revert l'intero match. Fatto: `FeeTest`.
3. **Test di `post`:** l'evento contiene gli stessi campi e lo stesso `orderHash` usati dal match; nessuna scrittura di storage (I8); revert su maker zero, token uguali o importi nulli. Fatto: `PostTest`.
4. **Test di I7:** nessuna combinazione di input porta i token di A a un indirizzo diverso da `b.maker`, e viceversa. Fatto: fuzz con submitter arbitrario.
5. **Test di identità dell'ordine:** stesso nonce e stessi campi del permit con maker diverso producono `orderHash` diversi. Fatto: `HashTest`.
6. **Test di coerenza con Permit2:** `permitWitnessStructHash` calcolato dal contratto coincide con quello verificato da Permit2 per la stessa firma. Fatto: `HashTest`.
7. **Test di firma incrociato:** ordini firmati con `eth_signTypedData_v4` da un client di riferimento, pubblicati con `post` e regolati con `matchOrders`.
8. **Halmos** sugli invarianti I1–I8, **Certora Prover** sulle regole critiche, **Gambit** per verificare con mutazioni che le specifiche rilevino i difetti. Fatto: [`docs/FORMAL.md`](FORMAL.md) (63 mutanti su 74 rilevati; sopravvissuti classificati).
9. **Verifica on-chain e fork test su 4663:** `eth_call` su proxy, implementazione e registro degli stock token (pausa, `isBlocked`, moltiplicatore); fork test con Permit2, USDG e uno stock token reali, inclusi token in pausa, maker in blocklist e maker delegati 7702.
10. **Deploy CREATE2** a indirizzo deterministico, sorgente verificato, `TREASURY` immutable, fee iniziale 0,00005 ETH. Script: `script/Deploy.s.sol`.

## Fonti

- [Permit2 — repository](https://github.com/Uniswap/permit2)
- [UniswapX — architettura reactor](https://github.com/Uniswap/UniswapX)
- [0x Settler](https://github.com/0xProject/0x-settler)
- [CoW Protocol — fair combinatorial auction](https://docs.cow.fi/cow-protocol/concepts/introduction/fair-combinatorial-auction)
- [DelegProof — analisi formale EIP-7702](https://eprint.iacr.org/2026/2060)
- [Robinhood Chain — analisi on-chain di stock token e filtri](https://xroot.dev/blog/robinhood-chain-read-directly)
- [Chainlink — feed tokenized equity Robinhood](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
- [Halmos — a16z](https://a16zcrypto.com/posts/article/symbolic-testing-with-halmos-leveraging-existing-tests-for-formal-verification/)
- [Certora — open source](https://www.certora.com/blog/certora-goes-open-source)
- [Solidity 0.8.35](https://www.soliditylang.org/blog/2026/04/29/solidity-0.8.35-release-announcement/)
