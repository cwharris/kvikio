# Copyright (c) 2023, NVIDIA CORPORATION. All rights reserved.
# See file LICENSE for terms.

from abc import ABC, abstractmethod
from enum import IntEnum

from libc.stdint cimport uintptr_t

from kvikio._lib.nvcomp_ll_cxx_api cimport cudaStream_t, nvcompStatus_t, nvcompType_t


class nvCompStatus(IntEnum):
    Success = nvcompStatus_t.nvcompSuccess,
    ErrorInvalidValue = nvcompStatus_t.nvcompErrorInvalidValue,
    ErrorNotSupported = nvcompStatus_t.nvcompErrorNotSupported,
    ErrorCannotDecompress = nvcompStatus_t.nvcompErrorCannotDecompress,
    ErrorBadChecksum = nvcompStatus_t.nvcompErrorBadChecksum,
    ErrorCannotVerifyChecksums = nvcompStatus_t.nvcompErrorCannotVerifyChecksums,
    ErrorCudaError = nvcompStatus_t.nvcompErrorCudaError,
    ErrorInternal = nvcompStatus_t.nvcompErrorInternal,


class nvCompType(IntEnum):
    CHAR = nvcompType_t.NVCOMP_TYPE_CHAR
    UCHAR = nvcompType_t.NVCOMP_TYPE_UCHAR
    SHORT = nvcompType_t.NVCOMP_TYPE_SHORT
    USHORT = nvcompType_t.NVCOMP_TYPE_USHORT
    INT = nvcompType_t.NVCOMP_TYPE_INT
    UINT = nvcompType_t.NVCOMP_TYPE_UINT
    LONGLONG = nvcompType_t.NVCOMP_TYPE_LONGLONG
    ULONGLONG = nvcompType_t.NVCOMP_TYPE_ULONGLONG
    BITS = nvcompType_t.NVCOMP_TYPE_BITS


class nvCompBatchAlgorithm(ABC):
    """Abstract class that provides interface to nvCOMP batched algorithms."""

    # TODO(akamenev): it might be possible to have a simpler implementation that
    # eilminates the need to have a separate implementation class for each algorithm,
    # potentially using fused types in Cython (similar to C++ templates),
    # but I could not figure out how to do that (e.g. each algorithm API set has
    # a different type for the options and so on).

    def get_compress_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ):
        """Get temporary space required for compression.

        Parameters
        ----------
        batch_size: int
            The number of items in the batch.
        max_uncompressed_chunk_bytes: int
            The maximum size in bytes of a chunk in the batch.

        Returns
        -------
        int
            The size in bytes of the required GPU workspace for compression.
        """
        err, temp_size = self._get_comp_temp_size(
            batch_size,
            max_uncompressed_chunk_bytes
        )
        if err != nvcompStatus_t.nvcompSuccess:
            raise RuntimeError(
                f"Could not get compress temp buffer size, "
                f"error: {nvCompStatus(err)!r}."
            )
        return temp_size

    @abstractmethod
    def _get_comp_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ) -> tuple[nvcompStatus_t, size_t]:
        """Algorithm-specific implementation."""
        ...

    def get_compress_chunk_size(self, size_t max_uncompressed_chunk_bytes):
        """Get the maximum size any chunk could compress to in the batch.

        Parameters
        ----------
        max_uncompressed_chunk_bytes: int
            The maximum size in bytes of a chunk in the batch.

        Returns
        -------
        int
            The maximum compressed size in bytes of the largest chunk. That is,
            the minimum amount of output memory required to be given to
            the corresponding *CompressAsync function.
        """
        err, comp_chunk_size = self._get_comp_chunk_size(max_uncompressed_chunk_bytes)
        if err != nvcompStatus_t.nvcompSuccess:
            raise RuntimeError(
                f"Could not get output buffer size, "
                f"error: {nvCompStatus(err)!r}."
            )
        return comp_chunk_size

    @abstractmethod
    def _get_comp_chunk_size(self, size_t max_uncompressed_chunk_bytes):
        """Algorithm-specific implementation."""
        ...

    def compress(
        self,
        uncomp_chunks,
        uncomp_chunk_sizes,
        size_t max_uncomp_chunk_bytes,
        size_t batch_size,
        temp_buf,
        comp_chunks,
        comp_chunk_sizes,
        stream,
    ):
        """Perform compression.

        Parameters
        ----------
        uncomp_chunks: cp.ndarray
            The pointers on the GPU, to uncompressed batched items.
        uncomp_chunk_sizes: cp.ndarray
            The size in bytes of each uncompressed batch item on the GPU.
        max_uncomp_chunk_bytes: int
            The maximum size in bytes of the largest chunk in the batch.
        batch_size: int
            The number of chunks to compress.
        temp_buf: cp.ndarray
            The temporary GPU workspace.
        comp_chunks: cp.ndarray
            (output) The pointers on the GPU, to the output location for each
            compressed batch item.
        comp_chunk_sizes: cp.ndarray
            (output) The compressed size in bytes of each chunk on the GPU.
        stream: cp.cuda.Stream
            CUDA stream.
        """
        err = self._compress(
            uncomp_chunks,
            uncomp_chunk_sizes,
            max_uncomp_chunk_bytes,
            batch_size,
            temp_buf,
            comp_chunks,
            comp_chunk_sizes,
            stream,
        )
        if err != nvcompStatus_t.nvcompSuccess:
            raise RuntimeError(f"Compression failed, error: {nvCompStatus(err)!r}.")

    @abstractmethod
    def _compress(
        self,
        uncomp_chunks,
        uncomp_chunk_sizes,
        size_t max_uncomp_chunk_bytes,
        size_t batch_size,
        temp_buf,
        comp_chunks,
        comp_chunk_sizes,
        stream
    ):
        """Algorithm-specific implementation."""
        ...

    def get_decompress_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ):
        """Get the amount of temp space required on the GPU for decompression.

        Parameters
        ----------
        batch_size: int
            The number of items in the batch.
        max_uncompressed_chunk_bytes: int
            The size in bytes of the largest chunk when uncompressed.

        Returns
        -------
        int
            The amount of temporary GPU space in bytes that will be
            required to decompress.
        """
        err, temp_size = self._get_decomp_temp_size(
            batch_size,
            max_uncompressed_chunk_bytes
        )
        if err != nvcompStatus_t.nvcompSuccess:
            raise RuntimeError(
                f"Could not get decompress temp buffer size, "
                f"error: {nvCompStatus(err)!r}."
            )

        return temp_size

    @abstractmethod
    def _get_decomp_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ):
        """Algorithm-specific implementation."""
        ...

    def decompress(
        self,
        comp_chunks,
        comp_chunk_sizes,
        size_t batch_size,
        temp_buf,
        uncomp_chunks,
        uncomp_chunk_sizes,
        actual_uncomp_chunk_sizes,
        statuses,
        stream,
    ):
        """Perform decompression.

        Parameters
        ----------
        comp_chunks: cp.ndarray
            The pointers on the GPU, to compressed batched items.
        comp_chunk_sizes: cp.ndarray
            The size in bytes of each compressed batch item on the GPU.
        batch_size: int
            The number of chunks to decompress.
        temp_buf: cp.ndarray
            The temporary GPU workspace.
        uncomp_chunks: cp.ndarray
            (output) The pointers on the GPU, to the output location for each
            decompressed batch item.
        uncomp_chunk_sizes: cp.ndarray
            The size in bytes of each decompress chunk location on the GPU.
        actual_uncomp_chunk_sizes: cp.ndarray
            (output) The actual decompressed size in bytes of each chunk on the GPU.
        statuses: cp.ndarray
            (output) The status for each chunk of whether it was decompressed or not.
        stream: cp.cuda.Stream
            CUDA stream.
        """
        err = self._decompress(
            comp_chunks,
            comp_chunk_sizes,
            batch_size,
            temp_buf,
            uncomp_chunks,
            uncomp_chunk_sizes,
            actual_uncomp_chunk_sizes,
            statuses,
            stream,
        )
        if err != nvcompStatus_t.nvcompSuccess:
            raise RuntimeError(f"Decompression failed, error: {nvCompStatus(err)!r}.")

    @abstractmethod
    def _decompress(
        self,
        comp_chunks,
        comp_chunk_sizes,
        size_t batch_size,
        temp_buf,
        uncomp_chunks,
        uncomp_chunk_sizes,
        actual_uncomp_chunk_sizes,
        statuses,
        stream,
    ):
        """Algorithm-specific implementation."""
        ...


cdef uintptr_t to_ptr(buf):
    return buf.data.ptr


cdef cudaStream_t to_stream(stream):
    return <cudaStream_t><size_t>stream.ptr


#
# LZ4 algorithm.
#
from kvikio._lib.nvcomp_ll_cxx_api cimport (
    nvcompBatchedLZ4CompressAsync,
    nvcompBatchedLZ4CompressGetMaxOutputChunkSize,
    nvcompBatchedLZ4CompressGetTempSize,
    nvcompBatchedLZ4DecompressAsync,
    nvcompBatchedLZ4DecompressGetTempSize,
    nvcompBatchedLZ4Opts_t,
)


class nvCompBatchAlgorithmLZ4(nvCompBatchAlgorithm):
    """LZ4 algorithm implementation."""

    algo_id: str = "lz4"

    options: nvcompBatchedLZ4Opts_t

    def __init__(self, data_type: int = 0):
        self.options = nvcompBatchedLZ4Opts_t(data_type)

    def _get_comp_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ) -> tuple[nvcompStatus_t, size_t]:
        cdef size_t temp_bytes = 0

        err = nvcompBatchedLZ4CompressGetTempSize(
            batch_size,
            max_uncompressed_chunk_bytes,
            self.options,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _get_comp_chunk_size(self, size_t max_uncompressed_chunk_bytes):
        cdef size_t max_compressed_bytes = 0

        err = nvcompBatchedLZ4CompressGetMaxOutputChunkSize(
            max_uncompressed_chunk_bytes,
            self.options,
            &max_compressed_bytes
        )

        return (err, max_compressed_bytes)

    def _compress(
        self,
        uncomp_chunks,
        uncomp_chunk_sizes,
        size_t max_uncomp_chunk_bytes,
        size_t batch_size,
        temp_buf,
        comp_chunks,
        comp_chunk_sizes,
        stream
    ):
        # Cast buffer pointers that have Python int type to appropriate C types
        # suitable for passing to nvCOMP API.
        return nvcompBatchedLZ4CompressAsync(
            <const void* const*>to_ptr(uncomp_chunks),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            max_uncomp_chunk_bytes,
            batch_size,
            <void*>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(comp_chunks),
            <size_t*>to_ptr(comp_chunk_sizes),
            self.options,
            to_stream(stream),
        )

    def _get_decomp_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ):
        cdef size_t temp_bytes = 0

        err = nvcompBatchedLZ4DecompressGetTempSize(
            batch_size,
            max_uncompressed_chunk_bytes,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _decompress(
        self,
        comp_chunks,
        comp_chunk_sizes,
        size_t batch_size,
        temp_buf,
        uncomp_chunks,
        uncomp_chunk_sizes,
        actual_uncomp_chunk_sizes,
        statuses,
        stream,
    ):
        # Cast buffer pointers that have Python int type to appropriate C types
        # suitable for passing to nvCOMP API.
        return nvcompBatchedLZ4DecompressAsync(
            <const void* const*>to_ptr(comp_chunks),
            <const size_t*>to_ptr(comp_chunk_sizes),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            <size_t*>NULL,
            batch_size,
            <void* const>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(uncomp_chunks),
            <nvcompStatus_t*>NULL,
            to_stream(stream),
        )

    def __repr__(self):
        return f"{self.__class__.__name__}(data_type={self.options['data_type']})"


#
# Gdeflate algorithm.
#
from kvikio._lib.nvcomp_ll_cxx_api cimport (
    nvcompBatchedGdeflateCompressAsync,
    nvcompBatchedGdeflateCompressGetMaxOutputChunkSize,
    nvcompBatchedGdeflateCompressGetTempSize,
    nvcompBatchedGdeflateDecompressAsync,
    nvcompBatchedGdeflateDecompressGetTempSize,
    nvcompBatchedGdeflateOpts_t,
)


class nvCompBatchAlgorithmGdeflate(nvCompBatchAlgorithm):
    """Gdeflate algorithm implementation."""

    algo_id: str = "gdeflate"

    options: nvcompBatchedGdeflateOpts_t

    def __init__(self, algo: int = 0):
        self.options = nvcompBatchedGdeflateOpts_t(algo)

    def _get_comp_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ) -> tuple[nvcompStatus_t, size_t]:
        cdef size_t temp_bytes = 0

        err = nvcompBatchedGdeflateCompressGetTempSize(
            batch_size,
            max_uncompressed_chunk_bytes,
            self.options,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _get_comp_chunk_size(self, size_t max_uncompressed_chunk_bytes):
        cdef size_t max_compressed_bytes = 0

        err = nvcompBatchedGdeflateCompressGetMaxOutputChunkSize(
            max_uncompressed_chunk_bytes,
            self.options,
            &max_compressed_bytes
        )

        return (err, max_compressed_bytes)

    def _compress(
        self,
        uncomp_chunks,
        uncomp_chunk_sizes,
        size_t max_uncomp_chunk_bytes,
        size_t batch_size,
        temp_buf,
        comp_chunks,
        comp_chunk_sizes,
        stream
    ):
        return nvcompBatchedGdeflateCompressAsync(
            <const void* const*>to_ptr(uncomp_chunks),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            max_uncomp_chunk_bytes,
            batch_size,
            <void*>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(comp_chunks),
            <size_t*>to_ptr(comp_chunk_sizes),
            self.options,
            to_stream(stream),
        )

    def _get_decomp_temp_size(
        self,
        size_t num_chunks,
        size_t max_uncompressed_chunk_bytes,
    ):
        cdef size_t temp_bytes = 0

        err = nvcompBatchedGdeflateDecompressGetTempSize(
            num_chunks,
            max_uncompressed_chunk_bytes,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _decompress(
        self,
        comp_chunks,
        comp_chunk_sizes,
        size_t batch_size,
        temp_buf,
        uncomp_chunks,
        uncomp_chunk_sizes,
        actual_uncomp_chunk_sizes,
        statuses,
        stream,
    ):
        return nvcompBatchedGdeflateDecompressAsync(
            <const void* const*>to_ptr(comp_chunks),
            <const size_t*>to_ptr(comp_chunk_sizes),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            <size_t*>NULL,
            batch_size,
            <void* const>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(uncomp_chunks),
            <nvcompStatus_t*>NULL,
            to_stream(stream),
        )

    def __repr__(self):
        return f"{self.__class__.__name__}(algo={self.options['algo']})"


#
# zstd algorithm.
#
from kvikio._lib.nvcomp_ll_cxx_api cimport (
    nvcompBatchedZstdCompressAsync,
    nvcompBatchedZstdCompressGetMaxOutputChunkSize,
    nvcompBatchedZstdCompressGetTempSize,
    nvcompBatchedZstdDecompressAsync,
    nvcompBatchedZstdDecompressGetTempSize,
    nvcompBatchedZstdOpts_t,
)


class nvCompBatchAlgorithmZstd(nvCompBatchAlgorithm):
    """zstd algorithm implementation."""

    algo_id: str = "zstd"

    options: nvcompBatchedZstdOpts_t

    def __init__(self):
        self.options = nvcompBatchedZstdOpts_t(0)

    def _get_comp_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ) -> tuple[nvcompStatus_t, size_t]:
        cdef size_t temp_bytes = 0

        err = nvcompBatchedZstdCompressGetTempSize(
            batch_size,
            max_uncompressed_chunk_bytes,
            self.options,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _get_comp_chunk_size(self, size_t max_uncompressed_chunk_bytes):
        cdef size_t max_compressed_bytes = 0

        err = nvcompBatchedZstdCompressGetMaxOutputChunkSize(
            max_uncompressed_chunk_bytes,
            self.options,
            &max_compressed_bytes
        )

        return (err, max_compressed_bytes)

    def _compress(
        self,
        uncomp_chunks,
        uncomp_chunk_sizes,
        size_t max_uncomp_chunk_bytes,
        size_t batch_size,
        temp_buf,
        comp_chunks,
        comp_chunk_sizes,
        stream
    ):
        return nvcompBatchedZstdCompressAsync(
            <const void* const*>to_ptr(uncomp_chunks),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            max_uncomp_chunk_bytes,
            batch_size,
            <void*>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(comp_chunks),
            <size_t*>to_ptr(comp_chunk_sizes),
            self.options,
            to_stream(stream),
        )

    def _get_decomp_temp_size(
        self,
        size_t num_chunks,
        size_t max_uncompressed_chunk_bytes,
    ):
        cdef size_t temp_bytes = 0

        err = nvcompBatchedZstdDecompressGetTempSize(
            num_chunks,
            max_uncompressed_chunk_bytes,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _decompress(
        self,
        comp_chunks,
        comp_chunk_sizes,
        size_t batch_size,
        temp_buf,
        uncomp_chunks,
        uncomp_chunk_sizes,
        actual_uncomp_chunk_sizes,
        statuses,
        stream,
    ):
        return nvcompBatchedZstdDecompressAsync(
            <const void* const*>to_ptr(comp_chunks),
            <const size_t*>to_ptr(comp_chunk_sizes),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            <size_t*>to_ptr(actual_uncomp_chunk_sizes),
            batch_size,
            <void* const>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(uncomp_chunks),
            <nvcompStatus_t*>to_ptr(statuses),
            to_stream(stream),
        )

    def __repr__(self):
        return f"{self.__class__.__name__}()"


#
# Snappy algorithm.
#
from kvikio._lib.nvcomp_ll_cxx_api cimport (
    nvcompBatchedSnappyCompressAsync,
    nvcompBatchedSnappyCompressGetMaxOutputChunkSize,
    nvcompBatchedSnappyCompressGetTempSize,
    nvcompBatchedSnappyDecompressAsync,
    nvcompBatchedSnappyDecompressGetTempSize,
    nvcompBatchedSnappyOpts_t,
)


class nvCompBatchAlgorithmSnappy(nvCompBatchAlgorithm):
    """Snappy algorithm implementation."""

    algo_id: str = "snappy"

    options: nvcompBatchedSnappyOpts_t

    def __init__(self):
        self.options = nvcompBatchedSnappyOpts_t(0)

    def _get_comp_temp_size(
        self,
        size_t batch_size,
        size_t max_uncompressed_chunk_bytes,
    ) -> tuple[nvcompStatus_t, size_t]:
        cdef size_t temp_bytes = 0

        err = nvcompBatchedSnappyCompressGetTempSize(
            batch_size,
            max_uncompressed_chunk_bytes,
            self.options,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _get_comp_chunk_size(self, size_t max_uncompressed_chunk_bytes):
        cdef size_t max_compressed_bytes = 0

        err = nvcompBatchedSnappyCompressGetMaxOutputChunkSize(
            max_uncompressed_chunk_bytes,
            self.options,
            &max_compressed_bytes
        )

        return (err, max_compressed_bytes)

    def _compress(
        self,
        uncomp_chunks,
        uncomp_chunk_sizes,
        size_t max_uncomp_chunk_bytes,
        size_t batch_size,
        temp_buf,
        comp_chunks,
        comp_chunk_sizes,
        stream
    ):
        return nvcompBatchedSnappyCompressAsync(
            <const void* const*>to_ptr(uncomp_chunks),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            max_uncomp_chunk_bytes,
            batch_size,
            <void*>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(comp_chunks),
            <size_t*>to_ptr(comp_chunk_sizes),
            self.options,
            to_stream(stream),
        )

    def _get_decomp_temp_size(
        self,
        size_t num_chunks,
        size_t max_uncompressed_chunk_bytes,
    ):
        cdef size_t temp_bytes = 0

        err = nvcompBatchedSnappyDecompressGetTempSize(
            num_chunks,
            max_uncompressed_chunk_bytes,
            &temp_bytes
        )

        return (err, temp_bytes)

    def _decompress(
        self,
        comp_chunks,
        comp_chunk_sizes,
        size_t batch_size,
        temp_buf,
        uncomp_chunks,
        uncomp_chunk_sizes,
        actual_uncomp_chunk_sizes,
        statuses,
        stream,
    ):
        return nvcompBatchedSnappyDecompressAsync(
            <const void* const*>to_ptr(comp_chunks),
            <const size_t*>to_ptr(comp_chunk_sizes),
            <const size_t*>to_ptr(uncomp_chunk_sizes),
            <size_t*>NULL,
            batch_size,
            <void* const>to_ptr(temp_buf),
            <size_t>temp_buf.nbytes,
            <void* const*>to_ptr(uncomp_chunks),
            <nvcompStatus_t*>NULL,
            to_stream(stream),
        )

    def __repr__(self):
        return f"{self.__class__.__name__}()"


SUPPORTED_ALGORITHMS = {
    a.algo_id: a for a in [
        nvCompBatchAlgorithmLZ4,
        nvCompBatchAlgorithmGdeflate,
        nvCompBatchAlgorithmZstd,
        nvCompBatchAlgorithmSnappy,
    ]
}
