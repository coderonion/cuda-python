# distutils: language = c++

# Copyright (c) 2024, NVIDIA CORPORATION & AFFILIATES. ALL RIGHTS RESERVED.
#
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

cimport cpython

from libc cimport stdlib
from libc.stdint cimport uint8_t
from libc.stdint cimport uint16_t
from libc.stdint cimport uint32_t
from libc.stdint cimport int32_t
from libc.stdint cimport int64_t
from libc.stdint cimport uint64_t
from libc.stdint cimport intptr_t

from enum import IntEnum


cdef extern from "dlpack.h" nogil:
    """
    #define DLPACK_TENSOR_UNUSED_NAME "dltensor"
    #define DLPACK_VERSIONED_TENSOR_UNUSED_NAME "dltensor_versioned"
    """
    ctypedef enum _DLDeviceType "DLDeviceType":
        _kDLCPU "kDLCPU"
        _kDLCUDA "kDLCUDA"
        _kDLCUDAHost "kDLCUDAHost"
        _kDLCUDAManaged "kDLCUDAManaged"

    ctypedef struct DLDevice:
        _DLDeviceType device_type
        int32_t device_id

    cdef enum DLDataTypeCode:
        kDLInt

    ctypedef struct DLDataType:
        uint8_t code
        uint8_t bits
        uint16_t lanes

    ctypedef struct DLTensor:
        void* data
        DLDevice device
        int32_t ndim
        DLDataType dtype
        int64_t* shape
        int64_t* strides
        uint64_t byte_offset

    ctypedef struct DLManagedTensor:
        DLTensor dl_tensor
        void* manager_ctx
        void (*deleter)(DLManagedTensor*)

    ctypedef struct DLPackVersion:
        uint32_t major
        uint32_t minor

    ctypedef struct DLManagedTensorVersioned:
        DLPackVersion version
        void* manager_ctx
        void (*deleter)(DLManagedTensorVersioned*)
        uint64_t flags
        DLTensor dl_tensor

    int DLPACK_MAJOR_VERSION
    int DLPACK_MINOR_VERSION

    const char* DLPACK_TENSOR_UNUSED_NAME
    const char* DLPACK_VERSIONED_TENSOR_UNUSED_NAME


cdef void pycapsule_deleter(object capsule):
    cdef DLManagedTensor* dlm_tensor
    cdef DLManagedTensorVersioned* dlm_tensor_ver
    # Do not invoke the deleter on a used capsule.
    if cpython.PyCapsule_IsValid(
            capsule, DLPACK_TENSOR_UNUSED_NAME):
        dlm_tensor = <DLManagedTensor*>(
            cpython.PyCapsule_GetPointer(
                capsule, DLPACK_TENSOR_UNUSED_NAME))
        if dlm_tensor.deleter:
            dlm_tensor.deleter(dlm_tensor)
    elif cpython.PyCapsule_IsValid(
            capsule, DLPACK_VERSIONED_TENSOR_UNUSED_NAME):
        dlm_tensor_ver = <DLManagedTensorVersioned*>(
            cpython.PyCapsule_GetPointer(
                capsule, DLPACK_VERSIONED_TENSOR_UNUSED_NAME))
        if dlm_tensor_ver.deleter:
            dlm_tensor_ver.deleter(dlm_tensor_ver)


cdef void deleter(DLManagedTensor* tensor) with gil:
    stdlib.free(tensor.dl_tensor.shape)
    if tensor.manager_ctx:
        cpython.Py_DECREF(<object>tensor.manager_ctx)
        tensor.manager_ctx = NULL
    stdlib.free(tensor)


cdef void versioned_deleter(DLManagedTensorVersioned* tensor) with gil:
    stdlib.free(tensor.dl_tensor.shape)
    if tensor.manager_ctx:
        cpython.Py_DECREF(<object>tensor.manager_ctx)
        tensor.manager_ctx = NULL
    stdlib.free(tensor)


cpdef object make_py_capsule(object buf, bint versioned) except +:
    cdef DLManagedTensor* dlm_tensor
    cdef DLManagedTensorVersioned* dlm_tensor_ver
    cdef DLTensor* dl_tensor
    cdef void* tensor_ptr
    cdef const char* capsule_name

    if versioned:
        dlm_tensor_ver = <DLManagedTensorVersioned*>(
            stdlib.malloc(sizeof(DLManagedTensorVersioned)))
        dlm_tensor_ver.version.major = DLPACK_MAJOR_VERSION
        dlm_tensor_ver.version.minor = DLPACK_MINOR_VERSION
        dlm_tensor_ver.manager_ctx = <void*>buf
        dlm_tensor_ver.deleter = versioned_deleter
        dlm_tensor_ver.flags = 0
        dl_tensor = &dlm_tensor_ver.dl_tensor
        tensor_ptr = dlm_tensor_ver
        capsule_name = DLPACK_VERSIONED_TENSOR_UNUSED_NAME
    else:
        dlm_tensor = <DLManagedTensor*>(
            stdlib.malloc(sizeof(DLManagedTensor)))
        dl_tensor = &dlm_tensor.dl_tensor
        dlm_tensor.manager_ctx = <void*>buf
        dlm_tensor.deleter = deleter
        tensor_ptr = dlm_tensor
        capsule_name = DLPACK_TENSOR_UNUSED_NAME

    dl_tensor.data = <void*><intptr_t>(int(buf.handle))
    dl_tensor.ndim = 1
    cdef int64_t* shape_strides = \
        <int64_t*>stdlib.malloc(sizeof(int64_t) * 2)
    shape_strides[0] = <int64_t>buf.size
    shape_strides[1] = 1  # redundant
    dl_tensor.shape = shape_strides
    dl_tensor.strides = NULL
    dl_tensor.byte_offset = 0

    cdef DLDevice* device = &dl_tensor.device
    # buf should be a Buffer instance
    if buf.is_device_accessible and not buf.is_host_accessible:
        device.device_type = _kDLCUDA
        device.device_id = buf.device_id
    elif buf.is_device_accessible and buf.is_host_accessible:
        device.device_type = _kDLCUDAHost
        device.device_id = 0
    elif not buf.is_device_accessible and buf.is_host_accessible:
        device.device_type = _kDLCPU
        device.device_id = 0
    else:  # not buf.is_device_accessible and not buf.is_host_accessible
        raise BufferError("invalid buffer")

    cdef DLDataType* dtype = &dl_tensor.dtype
    dtype.code = <uint8_t>kDLInt
    dtype.lanes = <uint16_t>1
    dtype.bits = <uint8_t>8

    cpython.Py_INCREF(buf)
    return cpython.PyCapsule_New(tensor_ptr, capsule_name, pycapsule_deleter)


class DLDeviceType(IntEnum):
    kDLCPU = _kDLCPU
    kDLCUDA = _kDLCUDA
    kDLCUDAHost = _kDLCUDAHost
    kDLCUDAManaged = _kDLCUDAManaged
