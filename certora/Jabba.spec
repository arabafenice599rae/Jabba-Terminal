/*
 * Jabba v2.4 — regole Certora per gli invarianti I1–I8 (docs/SPEC.md §7, §12 passo 8).
 *
 * Modello: Permit2 è sostituito da test/formal/Permit2Model.sol all'indirizzo canonico
 * (nonce monouso, scadenza, importo, trasferimento; registra destinatario, spender e witness).
 * TokenX / TokenY / TokenZ sono ERC-20 conformi, FeeOnTransferToken è il caso non conforme.
 * La chiamata di basso livello verso TREASURY è modellata senza effetti collaterali
 * (il lock di rientro è coperto dai test Foundry).
 */

using Permit2Model as p2;
using TokenX as tokX;
using TokenY as tokY;
using TokenZ as tokZ;
using FeeOnTransferToken as fot;
using HashOracle as oracle;

methods {
    function fee() external returns (uint256) envfree;
    function TREASURY() external returns (address) envfree;

    function p2.nonceUsed(address, uint256) external returns (bool) envfree;
    function p2.lastSpender(address) external returns (address) envfree;
    function p2.lastTo(address) external returns (address) envfree;
    function p2.lastRequested(address) external returns (uint256) envfree;
    function p2.lastWitness(address) external returns (bytes32) envfree;
    function p2.lastTypeStringOk(address) external returns (bool) envfree;
    function p2.pulls(address) external returns (uint256) envfree;
    function p2.orderWitness(address, uint256) external returns (bytes32) envfree;

    function tokX.balanceOf(address) external returns (uint256) envfree;
    function tokY.balanceOf(address) external returns (uint256) envfree;
    function tokZ.balanceOf(address) external returns (uint256) envfree;
    function fot.balanceOf(address) external returns (uint256) envfree;

    function oracle.orderHash(address, address, uint256, uint256, uint256, address, uint256, address, bytes32)
        external returns (bytes32) envfree;

    // Token scelti fra i contratti noti.
    function _.balanceOf(address) external => DISPATCHER(true);
    function _.transferFrom(address, address, uint256) external => DISPATCHER(true);

    // call{value} verso TREASURY: nessun effetto oltre al trasferimento di ETH.
    unresolved external in Jabba.matchOrders(Jabba.Side, Jabba.Side) => DISPATCH [] default NONDET;
}

// ------------------------------------------------------------------ definizioni

definition isSystem(address u) returns bool =
    u == currentContract || u == p2 || u == tokX || u == tokY || u == tokZ || u == fot || u == oracle;

/// A vende X e compra Y, B vende Y e compra X; maker esterni al sistema.
function setupXY(env e, Jabba.Side a, Jabba.Side b) {
    require a.permit.permitted.token == tokX && a.order.buyToken == tokY;
    require b.permit.permitted.token == tokY && b.order.buyToken == tokX;
    require !isSystem(a.maker) && !isSystem(b.maker);
    require !isSystem(e.msg.sender);
    require TREASURY() != currentContract && !isSystem(TREASURY());
}

// ------------------------------------------------------------------ vivacità

/// Esiste un match riuscito (le regole di sicurezza non sono vacue).
rule live_matchPossible(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    matchOrders(e, a, b);
    satisfy true;
}

// ------------------------------------------------------------------ I1

/// I1: ogni maker riceve esattamente quanto la controparte cede, e almeno il proprio buyAmount.
rule I1_receipt(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    mathint a0 = tokY.balanceOf(a.maker);
    mathint b0 = tokX.balanceOf(b.maker);

    matchOrders(e, a, b);

    mathint aGot = tokY.balanceOf(a.maker) - a0;
    mathint bGot = tokX.balanceOf(b.maker) - b0;
    assert aGot == to_mathint(b.permit.permitted.amount), "A non riceve esattamente b.sellAmount";
    assert bGot == to_mathint(a.permit.permitted.amount), "B non riceve esattamente a.sellAmount";
    assert aGot >= to_mathint(a.order.buyAmount), "A riceve meno del proprio buyAmount";
    assert bGot >= to_mathint(b.order.buyAmount), "B riceve meno del proprio buyAmount";
}

// ------------------------------------------------------------------ I2

/// I2 (conformi): ogni maker cede esattamente il sellAmount firmato.
rule I2_exactGive(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    mathint a0 = tokX.balanceOf(a.maker);
    mathint b0 = tokY.balanceOf(b.maker);

    matchOrders(e, a, b);

    assert a0 - tokX.balanceOf(a.maker) == to_mathint(a.permit.permitted.amount);
    assert b0 - tokY.balanceOf(b.maker) == to_mathint(b.permit.permitted.amount);
}

/// I2 (non conformi): con un token fee-on-transfer, se il match riesce ogni maker ha comunque
/// ricevuto almeno quanto la controparte ha ceduto.
rule I2_nonConformingReceipt(env e, Jabba.Side a, Jabba.Side b) {
    require a.permit.permitted.token == fot && a.order.buyToken == tokY;
    require b.permit.permitted.token == tokY && b.order.buyToken == fot;
    require !isSystem(a.maker) && !isSystem(b.maker) && !isSystem(e.msg.sender);
    require TREASURY() != currentContract && !isSystem(TREASURY());
    mathint a0 = tokY.balanceOf(a.maker);
    mathint b0 = fot.balanceOf(b.maker);

    matchOrders(e, a, b);

    assert fot.balanceOf(b.maker) - b0 >= to_mathint(a.permit.permitted.amount);
    assert tokY.balanceOf(a.maker) - a0 >= to_mathint(b.permit.permitted.amount);
}

// ------------------------------------------------------------------ I1/I2 generali

function isToken(address t) returns bool {
    return t == tokX || t == tokY || t == tokZ;
}

function balOf(address t, address u) returns mathint {
    if (t == tokX) {
        return tokX.balanceOf(u);
    } else if (t == tokY) {
        return tokY.balanceOf(u);
    }
    return tokZ.balanceOf(u);
}

/// I1 senza abbinamento prefissato: i quattro token sono scelti fra tre e i maker possono
/// coincidere. Rileva la rimozione di SelfMatch, SameToken e TokenMismatch.
rule I1_general(env e, Jabba.Side a, Jabba.Side b) {
    require isToken(a.permit.permitted.token) && isToken(a.order.buyToken);
    require isToken(b.permit.permitted.token) && isToken(b.order.buyToken);
    require !isSystem(a.maker) && !isSystem(b.maker) && !isSystem(e.msg.sender);
    require TREASURY() != currentContract && !isSystem(TREASURY());
    mathint a0 = balOf(a.order.buyToken, a.maker);
    mathint b0 = balOf(b.order.buyToken, b.maker);

    matchOrders(e, a, b);

    mathint aGot = balOf(a.order.buyToken, a.maker) - a0;
    mathint bGot = balOf(b.order.buyToken, b.maker) - b0;
    assert aGot == to_mathint(b.permit.permitted.amount) && aGot >= to_mathint(a.order.buyAmount);
    assert bGot == to_mathint(a.permit.permitted.amount) && bGot >= to_mathint(b.order.buyAmount);
}

/// I2 (non conformi), token fee-on-transfer venduto da B: A riceve comunque almeno quanto B cede.
rule I2_nonConformingReceiptA(env e, Jabba.Side a, Jabba.Side b) {
    require a.permit.permitted.token == tokX && a.order.buyToken == fot;
    require b.permit.permitted.token == fot && b.order.buyToken == tokX;
    require !isSystem(a.maker) && !isSystem(b.maker) && !isSystem(e.msg.sender);
    require TREASURY() != currentContract && !isSystem(TREASURY());
    mathint a0 = fot.balanceOf(a.maker);
    mathint b0 = tokX.balanceOf(b.maker);

    matchOrders(e, a, b);

    assert fot.balanceOf(a.maker) - a0 >= to_mathint(b.permit.permitted.amount);
    assert tokX.balanceOf(b.maker) - b0 >= to_mathint(a.permit.permitted.amount);
}

// ------------------------------------------------------------------ I3

/// I3: un match consuma entrambi i nonce con un solo prelievo per intero; il replay fallisce.
rule I3_onceAndWhole(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    require p2.pulls(a.maker) == 0 && p2.pulls(b.maker) == 0;

    matchOrders(e, a, b);

    assert p2.nonceUsed(a.maker, a.permit.nonce) && p2.nonceUsed(b.maker, b.permit.nonce);
    assert p2.pulls(a.maker) == 1 && p2.pulls(b.maker) == 1;
    assert p2.lastRequested(a.maker) == a.permit.permitted.amount;
    assert p2.lastRequested(b.maker) == b.permit.permitted.amount;

    matchOrders@withrevert(e, a, b);
    assert lastReverted, "replay riuscito";
}

/// I3: un ordine con nonce già consumato non si esegue.
rule I3_usedNonceReverts(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    require p2.nonceUsed(a.maker, a.permit.nonce) || p2.nonceUsed(b.maker, b.permit.nonce);
    matchOrders@withrevert(e, a, b);
    assert lastReverted;
}

// ------------------------------------------------------------------ I4

/// I4: solo setFee scrive la fee.
rule I4_onlySetFeeWritesFee(env e, method f, calldataarg args) filtered { f -> !f.isView && f.contract == currentContract } {
    uint256 before = fee();
    f(e, args);
    assert fee() != before => f.selector == sig:setFee(uint256).selector;
}

/// I4: setFee riesce solo per TREASURY e imposta esattamente il valore richiesto.
rule I4_setFeeOnlyTreasury(env e, uint256 newFee) {
    setFee@withrevert(e, newFee);
    bool reverted = lastReverted;
    assert !reverted => e.msg.sender == TREASURY() && fee() == newFee;
    assert e.msg.sender == TREASURY() && e.msg.value == 0 => !reverted;
}

/// I4: il contratto chiude ogni match senza token né ETH.
rule I4_noResidue(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    require tokX.balanceOf(currentContract) == 0 && tokY.balanceOf(currentContract) == 0;
    require nativeBalances[currentContract] == 0;

    matchOrders(e, a, b);

    assert tokX.balanceOf(currentContract) == 0 && tokY.balanceOf(currentContract) == 0;
    assert nativeBalances[currentContract] == 0;
}

// ------------------------------------------------------------------ I5

/// I5: msg.value è la fee corrente ed è inoltrato per intero a TREASURY.
rule I5_feeForwarded(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    address t = TREASURY();
    require e.msg.sender != t;
    uint256 feeBefore = fee();
    mathint t0 = nativeBalances[t];

    matchOrders(e, a, b);

    assert e.msg.value == feeBefore, "msg.value diverso dalla fee";
    assert to_mathint(nativeBalances[t]) == t0 + e.msg.value, "fee non inoltrata per intero";
}

// ------------------------------------------------------------------ I6

/// I6: per i token conformi la somma dei saldi dei due maker è conservata per token.
rule I6_conservation(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);
    mathint sx = tokX.balanceOf(a.maker) + tokX.balanceOf(b.maker);
    mathint sy = tokY.balanceOf(a.maker) + tokY.balanceOf(b.maker);

    matchOrders(e, a, b);

    assert tokX.balanceOf(a.maker) + tokX.balanceOf(b.maker) == sx;
    assert tokY.balanceOf(a.maker) + tokY.balanceOf(b.maker) == sy;
}

// ------------------------------------------------------------------ I7

/// I7: con submitter arbitrario ogni gamba va alla controparte, lo spender è Jabba e
/// il witness passato a Permit2 è quello dell'ordine firmato.
rule I7_counterpartyRecipient(env e, Jabba.Side a, Jabba.Side b) {
    setupXY(e, a, b);

    matchOrders(e, a, b);

    assert p2.lastTo(a.maker) == b.maker && p2.lastTo(b.maker) == a.maker, "destinatario diverso dalla controparte";
    assert p2.lastSpender(a.maker) == currentContract && p2.lastSpender(b.maker) == currentContract;
    assert p2.lastWitness(a.maker) == p2.orderWitness(a.order.buyToken, a.order.buyAmount), "witness di A alterato";
    assert p2.lastWitness(b.maker) == p2.orderWitness(b.order.buyToken, b.order.buyAmount), "witness di B alterato";
    assert p2.lastTypeStringOk(a.maker) && p2.lastTypeStringOk(b.maker), "type string del witness alterata";
}

// ------------------------------------------------------------------ I8

/// I8: post non modifica stato né sposta valore, in nessun contratto.
rule I8_postNoEffects(env e, Jabba.Side s) {
    storage before = lastStorage;
    mathint eth = nativeBalances[currentContract];

    post(e, s);

    storage after = lastStorage;
    assert after[currentContract] == before[currentContract], "post scrive lo storage di Jabba";
    assert after[p2] == before[p2] && after[tokX] == before[tokX] && after[tokY] == before[tokY];
    assert to_mathint(nativeBalances[currentContract]) == eth;
}

// ------------------------------------------------------------------ hash (§3)

/// orderHash ha la struttura attesa: maker + struct hash EIP-712 (permitted, spender = Jabba, nonce,
/// deadline, witness). Il valore del typehash è verificato da Halmos (check_H_orderHash).
rule H_orderHash(Jabba.Side s) {
    env e;
    bytes32 expected = oracle.orderHash(
        s.maker, s.permit.permitted.token, s.permit.permitted.amount, s.permit.nonce, s.permit.deadline,
        s.order.buyToken, s.order.buyAmount, currentContract, PERMIT_WITNESS_TYPEHASH(e)
    );
    assert orderHash(e, s) == expected;
}
