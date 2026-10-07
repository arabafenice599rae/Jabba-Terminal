# Verifica formale di Jabba v2.4

Passo 8 del piano di verifica (SPEC §12): gli invarianti I1–I8 sono proprietà eseguibili in
**Halmos** (esecuzione simbolica sul bytecode) e nel **Certora Prover** (verifica deduttiva). Il
**mutation testing** (mutazioni mirate + [Gambit](https://github.com/Certora/gambit)) misura se le
proprietà sanno distinguere il contratto corretto da versioni difettose.

Risultato: tutte le proprietà passano sul contratto corretto e **63 mutanti su 74** vengono
rilevati. Gli 11 sopravvissuti sono equivalenti al contratto corretto rispetto a I1–I8, oppure
riguardano comportamenti fuori dal modello coperti dai test Foundry; sono elencati uno per uno
più sotto.

## Esecuzione

```sh
# Halmos (anche in CI, job "halmos")
forge build --ast
halmos --contract JabbaHalmos --loop 8 --solver-timeout-assertion 0

# Certora Prover open source, in locale
export CERTORA=/percorso/build/certora    # contiene emv.jar, certoraRun.py, tac_optimizer
certora/run.sh                            # oppure: certora/run.sh --rule I1_receipt

# Mutation testing (ogni mutante: Halmos + Certora in una copia isolata del repo)
mutation/run.py --targeted --gambit --jobs 2 --resume
mutation/report.py                        # tabelle di questo documento
```

| File | Contenuto |
|---|---|
| `test/formal/Permit2Model.sol` | Modello astratto di Permit2, condiviso dai due strumenti |
| `test/formal/JabbaHalmos.t.sol` | 17 check Halmos |
| `certora/Jabba.spec`, `certora/jabba.conf`, `certora/harness/` | 18 regole Certora e harness |
| `mutation/targeted.json` | Mutazioni mirate |
| `mutation/run.py`, `mutation/report.py` | Esecuzione dei mutanti e report |
| `mutation/results.json` | Risultati per mutante (proprietà che lo rilevano) |

## Modello e ipotesi

- **Permit2** è sostituito da `Permit2Model` all'indirizzo canonico: nonce monouso, scadenza,
  importo richiesto ≤ permesso, trasferimento `owner → to`. La firma EIP-712 non è verificata;
  al suo posto il modello registra spender, destinatario, witness e type string di ogni
  chiamata, e le proprietà (I7) controllano che coincidano con l'ordine firmato. La correttezza
  di Permit2 stesso è un'ipotesi (contratto esterno già auditato).
- **Token**: ERC-20 conformi (`MockERC20`, tre istanze) e un token fee-on-transfer per il caso
  non conforme di I2. Token malevoli o rientranti sono fuori dal modello formale; li coprono i
  test Foundry (`TokenPerimeterTest`).
- **Tesoriere**: in Certora la `call` verso `TREASURY` trasferisce ETH senza altri effetti
  (`NONDET`); in Halmos è un indirizzo senza codice.
- **Compilazione**: Halmos verifica il bytecode di produzione (solc 0.8.37, via-IR). Certora
  supporta solc fino a 0.8.36 e con via-IR la sua analisi dei puntatori fallisce, quindi verifica
  la compilazione legacy di 0.8.36 (il pragma `^0.8.35` la ammette). I due strumenti coprono
  quindi due pipeline diverse dello stesso sorgente.
- **Hash**: Certora modella keccak256 in modo astratto e non conosce il contenuto delle stringhe
  lunghe copiate dal bytecode; `H_orderHash` verifica la struttura di `orderHash` (maker + struct
  hash EIP-712, campi e ordine) prendendo il typehash dal contratto. Il valore del typehash è
  verificato da Halmos (`check_H_orderHash`) e dai test Foundry (`HashTest`), che calcolano
  keccak256 in modo concreto.
- **Costruttore**: Certora parte da uno stato arbitrario e non esegue il costruttore; il
  costruttore è verificato solo da Halmos (`check_C_constructor`, `setUp`).
- **Vivacità e vacuità**: i check `live_*` di Halmos e le regole `live_validMatchNeverReverts`
  e `live_postValid` di Certora dimostrano che ogni match o `post` valido riesce (proprietà
  universale); `live_matchPossible` verifica solo che un match riuscito esista. In Certora
  `rule_sanity: basic` segnala inoltre come `SANITY_FAIL` le regole in cui nessun percorso
  raggiunge le asserzioni. La regola universale assume, oltre alle precondizioni di Jabba,
  saldi e allowance sufficienti, assenza di overflow, lock transient azzerato (inizio di una
  transazione) e contatori del modello non saturi.

## Matrice

Colonne Halmos/Certora: la proprietà passa sul contratto corretto (✅), in parte (parz., vedi
sopra) o non è verificata da quello strumento (—). Le colonne dei mutanti contano solo
**asserzioni violate**, non le regole diventate vacue. H = `orderHash` (§3), C = costruttore
(§6), live = vivacità (un match valido riesce, `setFee` e `post` validi riescono, due match
nella stessa transazione riescono).

| Proprietà | Halmos | Certora | Mutanti rilevati (mirati) | Mutanti Gambit rilevati |
|---|---|---|---|---|
| I1 | ✅ | ✅ | T1b, T2, T9, T10 | 4 |
| I2 | ✅ | ✅ | T1b, T5, T9, T10 | 12 |
| I3 | ✅ | ✅ | T10 | 0 |
| I4 | ✅ | ✅ | T6, T9 | 11 |
| I5 | ✅ | ✅ | T3, T7 | 8 |
| I6 | ✅ | ✅ | T1b, T9 | 0 |
| I7 | ✅ | ✅ | T1b, T8, T9 | 0 |
| I8 | ✅ | ✅ | T6 | 0 |
| H | ✅ | parz. | T4, T8 | 0 |
| C | ✅ | — | — | 1 |
| live | ✅ | ✅ | T1 | 35 |

## Mutazioni mirate

Una mutazione per ogni classe di difetto indicata nel piano. Quelle segnate "difetto doppio"
rimuovono anche la verifica di ricezione (`ShortReceipt`): da sola, ogni alterazione delle gambe
viene già bloccata da quella verifica e il match fa sempre revert (vedi T1), quindi per mettere
alla prova I3, I4 e I7 serve disattivare anche la seconda linea di difesa.

| Id | Obiettivo | Mutazione | Halmos | Certora | Esito |
|---|---|---|---|---|---|
| T1 | I7 | Destinatario invertito: la gamba di A torna ad A | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| T1b | I7 | Destinatario scelto dal submitter, senza verifica di ricezione (difetto doppio) | I1, I2, I6, I7 | I1, I2, I6, I7 | ucciso |
| T2 | I1 | Controllo di incrocio rimosso per il lato di A (bSellAmt >= a.buyAmount) | I1 | I1 | ucciso |
| T3 | I5 | Controllo fee indebolito: msg.value >= fee invece di == | I5 | I5 | ucciso |
| T4 | H | orderHash senza il maker | H | H | ucciso |
| T5 | I2 | Verifica dei delta di ricezione rimossa | I2 | I2 | ucciso |
| T6 | I8 | post scrive nello storage (fee = nonce) | I8 | I4, I8 | ucciso |
| T7 | I5 | Fee rimborsata al submitter invece che inviata a TREASURY | I5 | I5 | ucciso |
| T8 | I7 | Witness con campi invertiti (buyAmount, buyToken) | I7, H | I7, H | ucciso |
| T9 | I4 | Gamba di A verso il contratto stesso, senza verifica di ricezione (difetto doppio) | I1, I2, I4, I6, I7 | I1, I2, I4, I6, I7 | ucciso |
| T10 | I3 | Prelievo parziale (sellAmount − 1), senza verifica di ricezione (difetto doppio) | I1, I2, I3 | I1, I2, I3 | ucciso |

## Mutanti Gambit

Gambit: 63 mutanti — 52 uccisi, 11 sopravvissuti, 0 non compilabili, 0 in errore. Rilevati solo da Halmos: 8; solo da Certora: 3.

Solo Halmos: i mutanti del costruttore (g1–g6), che Certora non esegue, e la mancata
liberazione del lock (g51, g52), che si manifesta solo con due match nella stessa transazione:
Certora tratta ogni chiamata della regola come una transazione separata. Solo Certora: due
mutazioni aritmetiche della verifica di ricezione (g36, g45) su cui Halmos va in timeout, e g50
(esito della call al tesoriere ignorato), perché in Certora la call può fallire mentre in Halmos
il tesoriere è un indirizzo senza codice.

| Id | Mutazione | Halmos | Certora | Esito |
|---|---|---|---|---|
| g1 | IfStatement: `if (treasury == address(0)) revert ZeroAddress();` — `treasury == address(0)` → `true` | setUp | — | ucciso |
| g2 | IfStatement: `if (treasury == address(0)) revert ZeroAddress();` — `treasury == address(0)` → `false` | C | — | ucciso |
| g3 | DeleteExpression: `TREASURY = treasury;` — `TREASURY = treasury` → `assert(true)` | I4, I5, live | — | ucciso |
| g4 | DeleteExpression: `fee = initialFee;` — `fee = initialFee` → `assert(true)` | I4, live | — | ucciso |
| g5 | Assignment: `fee = initialFee;` — `initialFee` → `0` | I4, live | — | ucciso |
| g6 | Assignment: `fee = initialFee;` — `initialFee` → `1` | I4, live | — | ucciso |
| g7 | IfStatement: `if (_locked) revert Reentrancy();` — `_locked` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7, live) | ucciso |
| g8 | IfStatement: `if (_locked) revert Reentrancy();` — `_locked` → `false` | — | — | sopravvissuto |
| g9 | DeleteExpression: `_locked = true;` — `_locked = true` → `assert(true)` | — | — | sopravvissuto |
| g10 | Assignment: `_locked = true;` — `true` → `false` | — | — | sopravvissuto |
| g11 | IfStatement: `if (a.maker == address(0) \|\| b.maker == address(0)) revert ZeroMaker();` — `a.maker == address(0) \|\| b.maker == address(0)` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g12 | IfStatement: `if (a.maker == address(0) \|\| b.maker == address(0)) revert ZeroMaker();` — `a.maker == address(0) \|\| b.maker == address(0)` → `false` | — | — | sopravvissuto |
| g13 | IfStatement: `if (a.maker == b.maker) revert SelfMatch();` — `a.maker == b.maker` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g14 | IfStatement: `if (a.maker == b.maker) revert SelfMatch();` — `a.maker == b.maker` → `false` | — | — | sopravvissuto |
| g15 | IfStatement: `if (aSell == a.order.buyToken) revert SameToken();` — `aSell == a.order.buyToken` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g16 | IfStatement: `if (aSell == a.order.buyToken) revert SameToken();` — `aSell == a.order.buyToken` → `false` | — | — | sopravvissuto |
| g17 | IfStatement: `if (aSell != b.order.buyToken \|\| bSell != a.order.buyToken) revert TokenMismatch();` — `aSell != b.order.buyToken \|\| bSell != a.order.buyToken` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g18 | IfStatement: `if (aSell != b.order.buyToken \|\| bSell != a.order.buyToken) revert TokenMismatch();` — `aSell != b.order.buyToken \|\| bSell != a.order.buyToken` → `false` | I1 | I1 | ucciso |
| g19 | IfStatement: `if (aSellAmt == 0 \|\| bSellAmt == 0 \|\| a.order.buyAmount == 0 \|\| b.order.buyAmount == 0) revert ZeroAmount();` — `aSellAmt == 0 \|\| bSellAmt == 0 \|\| a.order.buyAmount == 0 \|\| b.order.buyAmount == 0` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g20 | IfStatement: `if (aSellAmt == 0 \|\| bSellAmt == 0 \|\| a.order.buyAmount == 0 \|\| b.order.buyAmount == 0) revert ZeroAmount();` — `aSellAmt == 0 \|\| bSellAmt == 0 \|\| a.order.buyAmount == 0 \|\| b.order.buyAmount == 0` → `false` | — | — | sopravvissuto |
| g21 | IfStatement: `if (aSellAmt < b.order.buyAmount \|\| bSellAmt < a.order.buyAmount) revert NotCrossed();` — `aSellAmt < b.order.buyAmount \|\| bSellAmt < a.order.buyAmount` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g22 | IfStatement: `if (aSellAmt < b.order.buyAmount \|\| bSellAmt < a.order.buyAmount) revert NotCrossed();` — `aSellAmt < b.order.buyAmount \|\| bSellAmt < a.order.buyAmount` → `false` | I1 | I1 | ucciso |
| g23 | SwapArgumentsOperator: `if (aSellAmt < b.order.buyAmount \|\| bSellAmt < a.order.buyAmount) revert NotCrossed();` — `aSellAmt < b.order.buyAmount` → `b.order.buyAmount < aSellAmt` | I1, live | I1 | ucciso |
| g24 | SwapArgumentsOperator: `if (aSellAmt < b.order.buyAmount \|\| bSellAmt < a.order.buyAmount) revert NotCrossed();` — `bSellAmt < a.order.buyAmount` → `a.order.buyAmount < bSellAmt` | I1, live | I1 | ucciso |
| g25 | IfStatement: `if (msg.value != fee) revert WrongFee();` — `msg.value != fee` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g26 | IfStatement: `if (msg.value != fee) revert WrongFee();` — `msg.value != fee` → `false` | I5 | I5 | ucciso |
| g27 | DeleteExpression: `_pull(a, b.maker);` — `_pull(a, b.maker)` → `assert(true)` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g28 | DeleteExpression: `_pull(b, a.maker);` — `_pull(b, a.maker)` → `assert(true)` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g29 | IfStatement: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g30 | IfStatement: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt` → `false` | I2 | I2 | ucciso |
| g31 | SwapArgumentsOperator: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt` → `bSellAmt < IERC20Balance(bSell).balanceOf(a.maker) - a0` | I2 | I2 | ucciso |
| g32 | BinaryOp: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `-` → `+` | I2 | I2 | ucciso |
| g33 | BinaryOp: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `-` → `*` | live | I2, live | ucciso |
| g34 | BinaryOp: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `-` → `/` | live | I2, live | ucciso |
| g35 | BinaryOp: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `-` → `%` | live | live | ucciso |
| g36 | BinaryOp: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `-` → `**` | — | I2, live | ucciso |
| g37 | SwapArgumentsOperator: `if (IERC20Balance(bSell).balanceOf(a.maker) - a0 < bSellAmt) revert ShortReceipt();` — `IERC20Balance(bSell).balanceOf(a.maker) - a0` → `a0 - IERC20Balance(bSell).balanceOf(a.maker)` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g38 | IfStatement: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt` → `true` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g39 | IfStatement: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt` → `false` | I2 | I2 | ucciso |
| g40 | SwapArgumentsOperator: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt` → `aSellAmt < IERC20Balance(aSell).balanceOf(b.maker) - b0` | I2 | I2 | ucciso |
| g41 | BinaryOp: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `-` → `+` | I2 | I2 | ucciso |
| g42 | BinaryOp: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `-` → `*` | live | I2 | ucciso |
| g43 | BinaryOp: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `-` → `/` | live | I2 | ucciso |
| g44 | BinaryOp: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `-` → `%` | live | live | ucciso |
| g45 | BinaryOp: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `-` → `**` | — | I2, live | ucciso |
| g46 | SwapArgumentsOperator: `if (IERC20Balance(aSell).balanceOf(b.maker) - b0 < aSellAmt) revert ShortReceipt();` — `IERC20Balance(aSell).balanceOf(b.maker) - b0` → `b0 - IERC20Balance(aSell).balanceOf(b.maker)` | live | live (vacue: I1, I2, I3, I4, I5, I6, I7) | ucciso |
| g47 | IfStatement: `if (msg.value != 0) {` — `msg.value != 0` → `true` | — | — | sopravvissuto |
| g48 | IfStatement: `if (msg.value != 0) {` — `msg.value != 0` → `false` | I4, I5 | I4, I5 | ucciso |
| g49 | IfStatement: `if (!ok) revert TreasuryTransferFailed();` — `!ok` → `true` | live | live | ucciso |
| g50 | IfStatement: `if (!ok) revert TreasuryTransferFailed();` — `!ok` → `false` | — | I4, I5 | ucciso |
| g51 | DeleteExpression: `_locked = false;` — `_locked = false` → `assert(true)` | live | — | ucciso |
| g52 | Assignment: `_locked = false;` — `false` → `true` | live | — | ucciso |
| g53 | IfStatement: `if (s.maker == address(0)) revert ZeroMaker();` — `s.maker == address(0)` → `true` | live | live (vacue: I4, I8) | ucciso |
| g54 | IfStatement: `if (s.maker == address(0)) revert ZeroMaker();` — `s.maker == address(0)` → `false` | — | — | sopravvissuto |
| g55 | IfStatement: `if (s.permit.permitted.token == s.order.buyToken) revert SameToken();` — `s.permit.permitted.token == s.order.buyToken` → `true` | live | live (vacue: I4, I8) | ucciso |
| g56 | IfStatement: `if (s.permit.permitted.token == s.order.buyToken) revert SameToken();` — `s.permit.permitted.token == s.order.buyToken` → `false` | — | — | sopravvissuto |
| g57 | IfStatement: `if (s.permit.permitted.amount == 0 \|\| s.order.buyAmount == 0) revert ZeroAmount();` — `s.permit.permitted.amount == 0 \|\| s.order.buyAmount == 0` → `true` | live | live (vacue: I4, I8) | ucciso |
| g58 | IfStatement: `if (s.permit.permitted.amount == 0 \|\| s.order.buyAmount == 0) revert ZeroAmount();` — `s.permit.permitted.amount == 0 \|\| s.order.buyAmount == 0` → `false` | — | — | sopravvissuto |
| g59 | IfStatement: `if (msg.sender != TREASURY) revert NotTreasury();` — `msg.sender != TREASURY` → `true` | I4, I5, live | I4 (vacue: I4) | ucciso |
| g60 | IfStatement: `if (msg.sender != TREASURY) revert NotTreasury();` — `msg.sender != TREASURY` → `false` | I4 | I4 | ucciso |
| g61 | DeleteExpression: `fee = newFee;` — `fee = newFee` → `assert(true)` | I4, I5 | I4 | ucciso |
| g62 | Assignment: `fee = newFee;` — `newFee` → `0` | I4, I5 | I4 | ucciso |
| g63 | Assignment: `fee = newFee;` — `newFee` → `1` | I4, I5 | I4 | ucciso |

## Lacune trovate dal mutation testing

La prima versione della suite (13 check Halmos, 14 regole Certora) lasciava 19 mutanti Gambit
sopravvissuti; il confronto fra i due strumenti ha mostrato altre lacune di Certora. Tutte chiuse:

| Mutanti | Lacuna | Proprietà aggiunta |
|---|---|---|
| g18 | I1 fissava l'abbinamento dei token (A vende X e compra Y, B il contrario): la rimozione di `TokenMismatch` non era esplorata | `I1_general`: i quattro token scelti fra tre, maker di B uguale o diverso da A |
| g30, g31, g32, g36 | Il token fee-on-transfer era venduto solo da A, quindi la verifica di ricezione sulla gamba di A non era messa alla prova | `I2_nonConformingReceiptA` |
| g32, g41 (solo Halmos) | Nei check non conformi il maker che riceve partiva con saldo zero, dove `saldo − a0` e `saldo + a0` coincidono | saldi iniziali simbolici in entrambi i check I2 non conformi |
| g2 | Nessuna proprietà sul costruttore | `check_C_constructor` |
| g51, g52 | Il lock di rientro non rilasciato vive fino a fine transazione: un secondo match nella stessa transazione (router, multicall) fallisce | `check_live_twoMatchesSameTx` |
| g33, g34, g35, g44, g49 | In Certora la vivacità era solo esistenziale (`satisfy`): mutanti che fanno revert solo per alcuni input validi (es. saldo iniziale zero, fee non nulla) passavano | `live_validMatchNeverReverts` |
| g53, g55, g57 | Nessuna regola Certora di vivacità per `post` | `live_postValid` |

## Sopravvissuti

| Mutanti | Mutazione | Motivo |
|---|---|---|
| g14, g16 | Rimozione di `SelfMatch` e `SameToken` | **Equivalenti.** Con maker uguali il saldo del buyToken non cambia; con token uguali il delta è `bSell − aSell`. In entrambi i casi `ShortReceipt` fa revert, quindi il comportamento osservabile coincide con il contratto corretto. |
| g12 | Rimozione di `ZeroMaker` in `matchOrders` | **Equivalente con Permit2 reale**, che rifiuta il firmatario zero; il modello non verifica firme. |
| g20 | Rimozione di `ZeroAmount` in `matchOrders` | Precondizione del §4, non un invariante: un ordine a importo zero firmato da entrambi non viola I1–I8. Coperto da `test_revert_zeroAmount`. |
| g54, g56, g58 | Rimozione delle validazioni di `post` | Precondizioni del §5; I8 vale comunque (nessun effetto). Coperte da `test_post_reverts`. |
| g8, g9, g10 | Lock di rientro disattivato | Il modello usa solo token benigni e un tesoriere senza codice: nessun rientro è possibile. Coperto da `test_reentrancy_blocked`. |
| g47 | `if (msg.value != 0)` → `if (true)` | **Equivalente nel modello**: una call da 0 wei a un tesoriere senza codice riesce. Differisce solo con un tesoriere che rifiuta ETH e fee zero. |

## Osservazioni

- La verifica di ricezione (`ShortReceipt`) è una seconda linea di difesa efficace: gran parte
  dei difetti singoli sulle gambe (destinatario, importo, token) non produce uno stato scorretto
  ma un revert. Per questo i check di vivacità sono essenziali: senza di essi quei mutanti
  passerebbero tutte le proprietà di sicurezza in modo vacuo.
- Halmos e Certora si completano: il primo esegue il costruttore e calcola keccak256 in modo
  concreto sul bytecode via-IR; il secondo ragiona su stato iniziale arbitrario (saldi, nonce,
  fee) e su tutti i metodi di tutti i contratti (regola parametrica di I4).
