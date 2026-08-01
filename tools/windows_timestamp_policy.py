#!/usr/bin/env python3
"""Read one RFC 3161 SHA-256 message imprint from an embedded PE signature.

This parser proves a narrow binary-format policy after the caller has established
Authenticode trust with Windows. It does not validate certificates or signatures.
"""

from __future__ import annotations

import hashlib
import os
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO


MAX_PE_OPTIONAL_HEADER_BYTES = 4096
MAX_PE_CERTIFICATE_TABLE_BYTES = 8 * 1024 * 1024
MAX_DER_ELEMENTS = 4096
MAX_DER_DEPTH = 24
MAX_DER_LENGTH_OCTETS = 4

_SIGNED_DATA_OID = bytes.fromhex("2a864886f70d010702")
_RFC3161_ATTRIBUTE_OID = bytes.fromhex("2b060104018237030301")
_TST_INFO_OID = bytes.fromhex("2a864886f70d0109100104")
_SHA256_OID = bytes.fromhex("608648016503040201")


class TimestampPolicyError(ValueError):
    """A bounded PE or DER timestamp-policy failure."""


@dataclass(frozen=True)
class TimestampMessageImprint:
    algorithm: str
    digest: str


@dataclass
class _DerBudget:
    remaining_elements: int

    def consume(self) -> None:
        if self.remaining_elements <= 0:
            raise TimestampPolicyError("DER element limit exceeded")
        self.remaining_elements -= 1


@dataclass(frozen=True)
class _DerValue:
    tag: int
    content: memoryview


class _DerReader:
    def __init__(
        self,
        data: bytes | memoryview,
        *,
        budget: _DerBudget | None = None,
        depth: int = 0,
    ):
        if depth > MAX_DER_DEPTH:
            raise TimestampPolicyError("DER depth limit exceeded")
        self._data = memoryview(data).cast("B")
        self._offset = 0
        self._budget = budget or _DerBudget(MAX_DER_ELEMENTS)
        self._depth = depth

    @property
    def at_end(self) -> bool:
        return self._offset == len(self._data)

    @property
    def remaining(self) -> memoryview:
        return self._data[self._offset :]

    def peek_tag(self) -> int | None:
        if self.at_end:
            return None
        return int(self._data[self._offset])

    def read(self, expected_tag: int | None = None) -> _DerValue:
        self._budget.consume()
        start = self._offset
        if start >= len(self._data):
            raise TimestampPolicyError("truncated DER tag")
        tag = int(self._data[start])
        if (tag & 0x1F) == 0x1F:
            raise TimestampPolicyError("high-tag-number DER is unsupported")
        cursor = start + 1
        if cursor >= len(self._data):
            raise TimestampPolicyError("truncated DER length")
        first_length = int(self._data[cursor])
        cursor += 1
        if first_length < 0x80:
            length = first_length
        else:
            length_octets = first_length & 0x7F
            if length_octets == 0 or length_octets > MAX_DER_LENGTH_OCTETS:
                raise TimestampPolicyError("invalid DER length")
            length_end = cursor + length_octets
            if length_end > len(self._data) or self._data[cursor] == 0:
                raise TimestampPolicyError("non-canonical DER length")
            length = int.from_bytes(self._data[cursor:length_end], "big")
            if length < 0x80:
                raise TimestampPolicyError("non-minimal DER length")
            cursor = length_end
        end = cursor + length
        if end > len(self._data):
            raise TimestampPolicyError("truncated DER value")
        if expected_tag is not None and tag != expected_tag:
            raise TimestampPolicyError("unexpected DER tag")
        self._offset = end
        return _DerValue(
            tag=tag,
            content=self._data[cursor:end],
        )

    def child(self, value: _DerValue) -> _DerReader:
        return _DerReader(
            value.content,
            budget=self._budget,
            depth=self._depth + 1,
        )

    def finish(self) -> None:
        if not self.at_end:
            raise TimestampPolicyError("unexpected trailing DER data")


def _validate_oid(value: _DerValue) -> bytes:
    if value.tag != 0x06 or not value.content:
        raise TimestampPolicyError("invalid DER object identifier")
    content = bytes(value.content)
    offset = 0
    while offset < len(content):
        if content[offset] == 0x80:
            raise TimestampPolicyError("non-minimal DER object identifier")
        while True:
            if offset >= len(content):
                raise TimestampPolicyError("truncated DER object identifier")
            octet = content[offset]
            offset += 1
            if octet & 0x80 == 0:
                break
    return content


def _validate_integer(value: _DerValue, *, exact: bytes | None = None) -> bytes:
    if value.tag != 0x02 or not value.content:
        raise TimestampPolicyError("invalid DER integer")
    content = bytes(value.content)
    if len(content) > 1 and (
        (content[0] == 0 and content[1] < 0x80)
        or (content[0] == 0xFF and content[1] >= 0x80)
    ):
        raise TimestampPolicyError("non-minimal DER integer")
    if exact is not None and content != exact:
        raise TimestampPolicyError("unexpected DER integer")
    return content


def _read_algorithm_oid(
    reader: _DerReader,
    *,
    null_parameters_only: bool = False,
) -> bytes:
    algorithm = reader.read(0x30)
    fields = reader.child(algorithm)
    oid = _validate_oid(fields.read(0x06))
    if not fields.at_end:
        parameters = fields.read()
        if null_parameters_only and (parameters.tag != 0x05 or parameters.content):
            raise TimestampPolicyError("unsupported algorithm parameters")
    fields.finish()
    return oid


def _read_one_signer_info(value: _DerValue, reader: _DerReader) -> _DerValue:
    signer_infos = reader.child(value)
    signer_info = signer_infos.read(0x30)
    signer_infos.finish()
    return signer_info


def _read_signed_data(
    value: _DerValue, reader: _DerReader
) -> tuple[_DerValue, _DerValue]:
    content_info = reader.child(value)
    if _validate_oid(content_info.read(0x06)) != _SIGNED_DATA_OID:
        raise TimestampPolicyError("content is not PKCS SignedData")
    explicit_content = content_info.read(0xA0)
    content_info.finish()

    explicit = content_info.child(explicit_content)
    signed_data_value = explicit.read(0x30)
    explicit.finish()
    signed_data = explicit.child(signed_data_value)
    _validate_integer(signed_data.read(0x02))

    digest_algorithms = signed_data.read(0x31)
    digest_reader = signed_data.child(digest_algorithms)
    _read_algorithm_oid(digest_reader)
    digest_reader.finish()

    encapsulated_content = signed_data.read(0x30)
    if signed_data.peek_tag() == 0xA0:
        signed_data.read(0xA0)
    if signed_data.peek_tag() == 0xA1:
        signed_data.read(0xA1)
    signer_info = _read_one_signer_info(signed_data.read(0x31), signed_data)
    signed_data.finish()
    return encapsulated_content, signer_info


def _read_signer_info_unsigned_attributes(
    signer_info: _DerValue,
    reader: _DerReader,
    *,
    required: bool,
) -> tuple[_DerValue | None, bytes]:
    fields = reader.child(signer_info)
    _validate_integer(fields.read(0x02))
    signer_identifier = fields.read()
    if signer_identifier.tag not in {0x30, 0x80}:
        raise TimestampPolicyError("invalid SignerInfo identifier")
    _read_algorithm_oid(fields)
    if fields.peek_tag() == 0xA0:
        fields.read(0xA0)
    _read_algorithm_oid(fields)
    signature = bytes(fields.read(0x04).content)
    if not signature:
        raise TimestampPolicyError("SignerInfo signature is empty")
    unsigned_attributes = None
    if fields.peek_tag() == 0xA1:
        unsigned_attributes = fields.read(0xA1)
    fields.finish()
    if required and unsigned_attributes is None:
        raise TimestampPolicyError("RFC 3161 unsigned attributes are missing")
    return unsigned_attributes, signature


def _read_timestamp_token(
    unsigned_attributes: _DerValue,
    reader: _DerReader,
) -> _DerValue:
    attributes = reader.child(unsigned_attributes)
    timestamp_token = None
    attribute_count = 0
    timestamp_count = 0
    while not attributes.at_end:
        attribute_count += 1
        attribute_value = attributes.read(0x30)
        attribute = attributes.child(attribute_value)
        oid = _validate_oid(attribute.read(0x06))
        values_value = attribute.read(0x31)
        attribute.finish()
        if oid != _RFC3161_ATTRIBUTE_OID:
            continue
        timestamp_count += 1
        values = attribute.child(values_value)
        timestamp_token = values.read(0x30)
        values.finish()
    if attribute_count != 1 or timestamp_count != 1 or timestamp_token is None:
        raise TimestampPolicyError("RFC 3161 timestamp token is missing or ambiguous")
    return timestamp_token


def _read_tst_info(
    encapsulated_content: _DerValue,
    reader: _DerReader,
) -> TimestampMessageImprint:
    encapsulated = reader.child(encapsulated_content)
    if _validate_oid(encapsulated.read(0x06)) != _TST_INFO_OID:
        raise TimestampPolicyError("timestamp content is not TSTInfo")
    explicit_content = encapsulated.read(0xA0)
    encapsulated.finish()

    explicit = encapsulated.child(explicit_content)
    octets = explicit.read(0x04)
    explicit.finish()
    tst_root = explicit.child(octets)
    tst_info_value = tst_root.read(0x30)
    tst_root.finish()
    tst_info = tst_root.child(tst_info_value)
    _validate_integer(tst_info.read(0x02), exact=b"\x01")
    _validate_oid(tst_info.read(0x06))

    message_imprint_value = tst_info.read(0x30)
    message_imprint = tst_info.child(message_imprint_value)
    algorithm = _read_algorithm_oid(message_imprint, null_parameters_only=True)
    digest = message_imprint.read(0x04)
    message_imprint.finish()
    if algorithm != _SHA256_OID or len(digest.content) != 32:
        raise TimestampPolicyError("timestamp message-imprint is not SHA-256")

    _validate_integer(tst_info.read(0x02))
    generated_time = tst_info.read(0x18)
    if not generated_time.content:
        raise TimestampPolicyError("timestamp generated time is empty")
    while not tst_info.at_end:
        tst_info.read()
    return TimestampMessageImprint(
        algorithm="sha256", digest=bytes(digest.content).hex()
    )


def _parse_timestamp_message_imprint(pkcs7: bytes) -> TimestampMessageImprint:
    root = _DerReader(pkcs7)
    content_info = root.read(0x30)
    if len(root.remaining) > 7 or any(root.remaining):
        raise TimestampPolicyError("invalid PKCS SignedData padding")

    _, outer_signer = _read_signed_data(content_info, root)
    unsigned_attributes, outer_signature = _read_signer_info_unsigned_attributes(
        outer_signer,
        root,
        required=True,
    )
    if unsigned_attributes is None:
        raise TimestampPolicyError("RFC 3161 unsigned attributes are missing")
    timestamp_token = _read_timestamp_token(unsigned_attributes, root)
    encapsulated, token_signer = _read_signed_data(timestamp_token, root)
    _read_signer_info_unsigned_attributes(token_signer, root, required=False)
    evidence = _read_tst_info(encapsulated, root)
    if hashlib.sha256(outer_signature).hexdigest() != evidence.digest:
        raise TimestampPolicyError(
            "timestamp message-imprint does not bind the signature"
        )
    return evidence


def _read_exact(handle: BinaryIO, size: int) -> bytes:
    value = handle.read(size)
    if len(value) != size:
        raise TimestampPolicyError("truncated PE data")
    return value


def _read_pe_pkcs7(target: Path) -> bytes:
    with target.open("rb") as handle:
        file_size = os.fstat(handle.fileno()).st_size
        if file_size < 64:
            raise TimestampPolicyError("truncated PE header")
        header = _read_exact(handle, 64)
        if header[:2] != b"MZ":
            raise TimestampPolicyError("invalid DOS header")
        pe_offset = struct.unpack_from("<I", header, 0x3C)[0]
        if pe_offset > file_size - 24:
            raise TimestampPolicyError("invalid PE header offset")
        handle.seek(pe_offset)
        pe_header = _read_exact(handle, 24)
        if pe_header[:4] != b"PE\x00\x00":
            raise TimestampPolicyError("invalid PE signature")
        optional_size = struct.unpack_from("<H", pe_header, 20)[0]
        if optional_size == 0 or optional_size > MAX_PE_OPTIONAL_HEADER_BYTES:
            raise TimestampPolicyError("invalid PE optional-header size")
        optional = _read_exact(handle, optional_size)
        magic = struct.unpack_from("<H", optional, 0)[0]
        if magic == 0x10B:
            directory_offset = 96
            directory_count_offset = 92
        elif magic == 0x20B:
            directory_offset = 112
            directory_count_offset = 108
        else:
            raise TimestampPolicyError("unsupported PE optional header")
        security_directory_offset = directory_offset + (4 * 8)
        if (
            optional_size < security_directory_offset + 8
            or struct.unpack_from("<I", optional, directory_count_offset)[0] < 5
        ):
            raise TimestampPolicyError("PE certificate directory is missing")
        certificate_offset, certificate_size = struct.unpack_from(
            "<II",
            optional,
            security_directory_offset,
        )
        if (
            certificate_offset == 0
            or certificate_offset % 8 != 0
            or certificate_size < 8
            or certificate_size > MAX_PE_CERTIFICATE_TABLE_BYTES
            or certificate_offset > file_size - certificate_size
        ):
            raise TimestampPolicyError("invalid PE certificate directory")
        handle.seek(certificate_offset)
        certificate_table = _read_exact(handle, certificate_size)

    record_length, revision, certificate_type = struct.unpack_from(
        "<IHH", certificate_table, 0
    )
    aligned_length = (record_length + 7) & ~7
    if (
        record_length < 8
        or aligned_length != len(certificate_table)
        or revision != 0x0200
        or certificate_type != 0x0002
        or any(certificate_table[record_length:])
    ):
        raise TimestampPolicyError("ambiguous PE certificate table")
    return certificate_table[8:record_length]


def read_timestamp_message_imprint(target: Path) -> TimestampMessageImprint:
    """Return one SHA-256 imprint that is bound to the outer Authenticode signature."""
    try:
        return _parse_timestamp_message_imprint(_read_pe_pkcs7(target))
    except (OSError, OverflowError, struct.error) as error:
        raise TimestampPolicyError("timestamp policy input is invalid") from error
