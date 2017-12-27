// Bitcoin transaction parsing library - modified for DOGE

// Copyright 2016 rain <https://keybase.io/rain>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// https://en.bitcoin.it/wiki/Protocol_documentation#tx
//
// Raw Bitcoin transaction structure:
//
// field     | size | type     | description
// version   | 4    | int32    | transaction version number
// n_tx_in   | 1-9  | var_int  | number of transaction inputs
// tx_in     | 41+  | tx_in[]  | list of transaction inputs
// n_tx_out  | 1-9  | var_int  | number of transaction outputs
// tx_out    | 9+   | tx_out[] | list of transaction outputs
// lock_time | 4    | uint32   | block number / timestamp at which tx locked
//
// Transaction input (tx_in) structure:
//
// field      | size | type     | description
// previous   | 36   | outpoint | Previous output transaction reference
// script_len | 1-9  | var_int  | Length of the signature script
// sig_script | ?    | uchar[]  | Script for confirming transaction authorization
// sequence   | 4    | uint32   | Sender transaction version
//
// OutPoint structure:
//
// field      | size | type     | description
// hash       | 32   | char[32] | The hash of the referenced transaction
// index      | 4    | uint32   | The index of this output in the referenced transaction
//
// Transaction output (tx_out) structure:
//
// field         | size | type     | description
// value         | 8    | int64    | Transaction value (Satoshis)
// pk_script_len | 1-9  | var_int  | Length of the public key script
// pk_script     | ?    | uchar[]  | Public key as a Bitcoin script.
//
// Variable integers (var_int) can be encoded differently depending
// on the represented value, to save space. Variable integers always
// precede an array of a variable length data type (e.g. tx_in).
//
// Variable integer encodings as a function of represented value:
//
// value           | bytes  | format
// <0xFD (253)     | 1      | uint8
// <=0xFFFF (65535)| 3      | 0xFD followed by length as uint16
// <=0xFFFF FFFF   | 5      | 0xFE followed by length as uint32
// -               | 9      | 0xFF followed by length as uint64
//
// Public key scripts `pk_script` are set on the output and can
// take a number of forms. The regular transaction script is
// called 'pay-to-pubkey-hash' (P2PKH):
//
// OP_DUP OP_HASH160 <pubKeyHash> OP_EQUALVERIFY OP_CHECKSIG
//
// OP_x are Bitcoin script opcodes. The bytes representation (including
// the 0x14 20-byte stack push) is:
//
// 0x76 0xA9 0x14 <pubKeyHash> 0x88 0xAC
//
// The <pubKeyHash> is the ripemd160 hash of the sha256 hash of
// the public key, preceded by a network version byte. (21 bytes total)
//
// Network version bytes: 0x00 (mainnet); 0x6f (testnet); 0x34 (namecoin)
//
// The Bitcoin address is derived from the pubKeyHash. The binary form is the
// pubKeyHash, plus a checksum at the end.  The checksum is the first 4 bytes
// of the (32 byte) double sha256 of the pubKeyHash. (25 bytes total)
// This is converted to base58 to form the publicly used Bitcoin address.
// Mainnet P2PKH transaction scripts are to addresses beginning with '1'.
//
// P2SH ('pay to script hash') scripts only supply a script hash. The spender
// must then provide the script that would allow them to redeem this output.
// This allows for arbitrarily complex scripts to be funded using only a
// hash of the script, and moves the onus on providing the script from
// the spender to the redeemer.
//
// The P2SH script format is simple:
//
// OP_HASH160 <scriptHash> OP_EQUAL
//
// 0xA9 0x14 <scriptHash> 0x87
//
// The <scriptHash> is the ripemd160 hash of the sha256 hash of the
// redeem script. The P2SH address is derived from the scriptHash.
// Addresses are the scriptHash with a version prefix of 5, encoded as
// Base58check. These addresses begin with a '3'.

pragma solidity ^0.4.11;

// parse a raw bitcoin transaction byte array
library DogeTx {

    uint constant p = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f;  // secp256k1
    uint constant q = (p + 1) / 4;

    // Convert a variable integer into something useful and return it and
    // the index to after it.
    function parseVarInt(bytes txBytes, uint pos) private pure returns (uint, uint) {
        // the first byte tells us how big the integer is
        var ibit = uint8(txBytes[pos]);
        pos += 1;  // skip ibit

        if (ibit < 0xfd) {
            return (ibit, pos);
        } else if (ibit == 0xfd) {
            return (getBytesLE(txBytes, pos, 16), pos + 2);
        } else if (ibit == 0xfe) {
            return (getBytesLE(txBytes, pos, 32), pos + 4);
        } else if (ibit == 0xff) {
            return (getBytesLE(txBytes, pos, 64), pos + 8);
        }
    }
    // convert little endian bytes to uint
    function getBytesLE(bytes data, uint pos, uint bits) private pure returns (uint) {
        if (bits == 8) {
            return uint8(data[pos]);
        } else if (bits == 16) {
            return uint16(data[pos])
                 + uint16(data[pos + 1]) * 2 ** 8;
        } else if (bits == 32) {
            return uint32(data[pos])
                 + uint32(data[pos + 1]) * 2 ** 8
                 + uint32(data[pos + 2]) * 2 ** 16
                 + uint32(data[pos + 3]) * 2 ** 24;
        } else if (bits == 64) {
            return uint64(data[pos])
                 + uint64(data[pos + 1]) * 2 ** 8
                 + uint64(data[pos + 2]) * 2 ** 16
                 + uint64(data[pos + 3]) * 2 ** 24
                 + uint64(data[pos + 4]) * 2 ** 32
                 + uint64(data[pos + 5]) * 2 ** 40
                 + uint64(data[pos + 6]) * 2 ** 48
                 + uint64(data[pos + 7]) * 2 ** 56;
        }
    }

    function parseTransaction(bytes txBytes) internal pure
             returns (uint, bytes20, bytes32, bool)
    {
        uint pos;
        uint[] memory input_script_lens;
        uint[] memory input_script_starts;
        uint[] memory output_script_lens;
        uint[] memory output_script_starts;
        uint[] memory output_values;
        bytes20 output_address;

        pos = 4;  // skip version
        (input_script_starts, input_script_lens, pos) = scanInputs(txBytes, pos, 0);

        bytes32 inputPubKey;
        bool inputPubKeyOdd;
        (inputPubKey, inputPubKeyOdd) = getInputPubKey(txBytes, input_script_starts[0]);

        (output_values, output_script_starts, output_script_lens, pos) = scanOutputs(txBytes, pos, 1);
        output_address = parseOutputScript(txBytes, output_script_starts[0], output_script_lens[0]);

        return (output_values[0], output_address, inputPubKey, inputPubKeyOdd);
    }

    // scan the full transaction bytes and return the first two output
    // values (in satoshis) and addresses (in binary)
    function getFirstTwoOutputs(bytes txBytes) internal pure
             returns (uint, bytes20, uint, bytes20)
    {
        uint pos;
        uint[] memory input_script_lens;
        uint[] memory output_script_lens;
        uint[] memory script_starts;
        uint[] memory output_values;
        bytes20[] memory output_addresses = new bytes20[](2);

        pos = 4;  // skip version

        (, input_script_lens, pos) = scanInputs(txBytes, pos, 0);

        (output_values, script_starts, output_script_lens, pos) = scanOutputs(txBytes, pos, 2);

        for (uint i = 0; i < 2; i++) {
            var pkhash = parseOutputScript(txBytes, script_starts[i], output_script_lens[i]);
            output_addresses[i] = pkhash;
        }

        return (output_values[0], output_addresses[0],
                output_values[1], output_addresses[1]);
    }

    function getFirstInputPubKey(bytes txBytes) private pure
             returns (bytes32, bool)
    {
        uint pos;
        uint[] memory input_script_lens;
        // The line above fires a warning because the variable hasn't been used.
        // It's probably NOT a good idea to comment it until the function is more or less finished because the warning could be useful for debugging.

        pos = 4;  // skip version

        (, pos) = parseVarInt(txBytes, pos);
        return getInputPubKey(txBytes, pos);
    }

    function getInputPubKey(bytes txBytes, uint pos) private pure
             returns (bytes32, bool)
    {
        pos += 36;  // skip outpoint
        (, pos) = parseVarInt(txBytes, pos);
        bytes32 pubKey;
        bool odd;
        (, pubKey, odd, pos) = parseScriptSig(txBytes, pos);
        return (pubKey, odd);
    }

    // Check whether `btcAddress` is in the transaction outputs *and*
    // whether *at least* `value` has been sent to it.
    function checkValueSent(bytes txBytes, bytes20 btcAddress, uint value) private pure
             returns (bool)
    {
        uint pos = 4;  // skip version
        (,, pos) = scanInputs(txBytes, pos, 0);  // find end of inputs

        // scan *all* the outputs and find where they are
        var (output_values, script_starts, output_script_lens,) = scanOutputs(txBytes, pos, 0);

        // look at each output and check whether it at least value to btcAddress
        for (uint i = 0; i < output_values.length; i++) {
            var pkhash = parseOutputScript(txBytes, script_starts[i], output_script_lens[i]);
            if (pkhash == btcAddress && output_values[i] >= value) {
                return true;
            }
        }
    }
    // scan the inputs and find the script lengths.
    // return an array of script lengths and the end position
    // of the inputs.
    // takes a 'stop' argument which sets the maximum number of
    // outputs to scan through. stop=0 => scan all.
    function scanInputs(bytes txBytes, uint pos, uint stop) private pure
             returns (uint[], uint[], uint)
    {
        uint n_inputs;
        uint halt;
        uint script_len;

        (n_inputs, pos) = parseVarInt(txBytes, pos);

        if (stop == 0 || stop > n_inputs) {
            halt = n_inputs;
        } else {
            halt = stop;
        }

        uint[] memory script_starts = new uint[](halt);
        uint[] memory script_lens = new uint[](halt);

        for (uint256 i = 0; i < halt; i++) {
            script_starts[i] = pos;
            pos += 36;  // skip outpoint
            (script_len, pos) = parseVarInt(txBytes, pos);
            script_lens[i] = script_len;
            pos += script_len + 4;  // skip sig_script, seq
        }

        return (script_starts, script_lens, pos);
    }
    // scan the outputs and find the values and script lengths.
    // return array of values, array of script lengths and the
    // end position of the outputs.
    // takes a 'stop' argument which sets the maximum number of
    // outputs to scan through. stop=0 => scan all.
    function scanOutputs(bytes txBytes, uint pos, uint stop) private pure
             returns (uint[], uint[], uint[], uint)
    {
        uint n_outputs;
        uint halt;
        uint script_len;

        (n_outputs, pos) = parseVarInt(txBytes, pos);

        if (stop == 0 || stop > n_outputs) {
            halt = n_outputs;
        } else {
            halt = stop;
        }

        uint[] memory script_starts = new uint[](halt);
        uint[] memory script_lens = new uint[](halt);
        uint[] memory output_values = new uint[](halt);

        for (uint256 i = 0; i < halt; i++) {
            output_values[i] = getBytesLE(txBytes, pos, 64);
            pos += 8;

            (script_len, pos) = parseVarInt(txBytes, pos);
            script_starts[i] = pos;
            script_lens[i] = script_len;
            pos += script_len;
        }

        return (output_values, script_starts, script_lens, pos);
    }
    // Slice 20 contiguous bytes from bytes `data`, starting at `start`
    function sliceBytes20(bytes data, uint start) private pure returns (bytes20) {
        uint160 slice = 0;
        for (uint160 i = 0; i < 20; i++) {
            slice += uint160(data[i + start]) << (8 * (19 - i));
        }
        return bytes20(slice);
    }
    // returns true if the bytes located in txBytes by pos and
    // script_len represent a P2PKH script
    function isP2PKH(bytes txBytes, uint pos, uint script_len) private pure returns (bool) {
        return (script_len == 25)           // 20 byte pubkeyhash + 5 bytes of script
            && (txBytes[pos] == 0x76)       // OP_DUP
            && (txBytes[pos + 1] == 0xa9)   // OP_HASH160
            && (txBytes[pos + 2] == 0x14)   // bytes to push
            && (txBytes[pos + 23] == 0x88)  // OP_EQUALVERIFY
            && (txBytes[pos + 24] == 0xac); // OP_CHECKSIG
    }
    // returns true if the bytes located in txBytes by pos and
    // script_len represent a P2SH script
    function isP2SH(bytes txBytes, uint pos, uint script_len) private pure returns (bool) {
        return (script_len == 23)           // 20 byte scripthash + 3 bytes of script
            && (txBytes[pos + 0] == 0xa9)   // OP_HASH160
            && (txBytes[pos + 1] == 0x14)   // bytes to push
            && (txBytes[pos + 22] == 0x87); // OP_EQUAL
    }
    // Get the pubkeyhash / scripthash from an output script. Assumes
    // pay-to-pubkey-hash (P2PKH) or pay-to-script-hash (P2SH) outputs.
    // Returns the pubkeyhash/ scripthash, or zero if unknown output.
    function parseOutputScript(bytes txBytes, uint pos, uint script_len) private pure
             returns (bytes20)
    {
        if (isP2PKH(txBytes, pos, script_len)) {
            return sliceBytes20(txBytes, pos + 3);
        } else if (isP2SH(txBytes, pos, script_len)) {
            return sliceBytes20(txBytes, pos + 2);
        } else {
            return;
        }
    }

    // Parse a P2PKH scriptSig
    function parseScriptSig(bytes txBytes, uint pos) private pure
             returns (bytes, bytes32, bool, uint)
    {
        bytes memory sig;
        bytes32 pubKey;
        bool odd;
        (sig, pos) = parseSignature(txBytes, pos);
        (pubKey, odd, pos) = parsePubKey(txBytes, pos);
        return (sig, pubKey, odd, pos);
    }

    // Extract a signature
    function parseSignature(bytes txBytes, uint pos) private pure
             returns (bytes, uint)
    {
        uint8 op;
        bytes memory sig;
        (op, pos) = getOpcode(txBytes, pos);
        require(op >= 9 && op <= 73);
        require(uint8(txBytes[pos]) == 0x30);
        //FIXME: Copy signature
        pos += op;
        return (sig, pos);
    }

    // Extract public key
    function parsePubKey(bytes txBytes, uint pos) private pure
             returns (bytes32, bool, uint)
    {
        uint8 op;
        (op, pos) = getOpcode(txBytes, pos);
        //FIXME: Add support for uncompressed public keys
        require(op == 33);
        bytes32 pubKey;
        bool odd = txBytes[pos] == 0x03;
        pos += 1;
        assembly {
            pubKey := mload(add(add(txBytes, 0x20), pos))
        }
        pos += 32;
        return (pubKey, odd, pos);
    }

    // Read next opcode from script
    function getOpcode(bytes txBytes, uint pos) private pure
             returns (uint8, uint)
    {
        return (uint8(txBytes[pos]), pos + 1);
    }

    function expmod(uint256 base, uint256 e, uint256 m) internal returns (uint256 o) {
        assembly {
            // pointer to free memory
            let p := mload(0x40)
            mstore(p, 0x20)             // Length of Base
            mstore(add(p, 0x20), 0x20)  // Length of Exponent
            mstore(add(p, 0x40), 0x20)  // Length of Modulus
            mstore(add(p, 0x60), base)  // Base
            mstore(add(p, 0x80), e)     // Exponent
            mstore(add(p, 0xa0), m)     // Modulus
            // call modexp precompile!
            if iszero(call(not(0), 0x05, 0, p, 0xc0, p, 0x20)) {
                revert(0, 0)
            }
            // data
            o := mload(p)
        }
    }

    function pub2address(uint x, bool odd) internal returns (address) {
        uint yy = mulmod(x, x, p);
        yy = mulmod(yy, x, p);
        yy = addmod(yy, 7, p);
        uint y = expmod(yy, q, p);
        if (((y & 1) == 1) != odd) {
          y = p - y;
        }
        require(yy == mulmod(y, y, p));
        return address(keccak256(x, y));
    }
}
