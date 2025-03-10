# Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import sys
import tempfile
import time
import unittest

import numpy as np
from dygraph_to_static_utils import (
    Dy2StTestBase,
    enable_to_static_guard,
    test_legacy_and_pir,
)
from predictor_utils import PredictorTools

import paddle
from paddle import base
from paddle.base.framework import unique_name
from paddle.base.param_attr import ParamAttr
from paddle.jit.translated_layer import INFER_MODEL_SUFFIX, INFER_PARAMS_SUFFIX
from paddle.nn import BatchNorm, Linear

# Note: Set True to eliminate randomness.
#     1. For one operation, cuDNN has several algorithms,
#        some algorithm results are non-deterministic, like convolution algorithms.
if base.is_compiled_with_cuda():
    base.set_flags({'FLAGS_cudnn_deterministic': True})

SEED = 2020


class ConvBNLayer(paddle.nn.Layer):
    def __init__(
        self,
        num_channels,
        filter_size,
        num_filters,
        stride,
        padding,
        channels=None,
        num_groups=1,
        act='relu',
        use_cudnn=True,
        name=None,
    ):
        super().__init__()

        self._conv = paddle.nn.Conv2D(
            in_channels=num_channels,
            out_channels=num_filters,
            kernel_size=filter_size,
            stride=stride,
            padding=padding,
            groups=num_groups,
            weight_attr=ParamAttr(
                initializer=paddle.nn.initializer.KaimingUniform(),
                name=self.full_name() + "_weights",
            ),
            bias_attr=False,
        )

        self._batch_norm = BatchNorm(
            num_filters,
            act=act,
            param_attr=ParamAttr(name=self.full_name() + "_bn" + "_scale"),
            bias_attr=ParamAttr(name=self.full_name() + "_bn" + "_offset"),
            moving_mean_name=self.full_name() + "_bn" + '_mean',
            moving_variance_name=self.full_name() + "_bn" + '_variance',
        )

    def forward(self, inputs, if_act=False):
        y = self._conv(inputs)
        y = self._batch_norm(y)
        if if_act:
            y = paddle.nn.functional.relu6(y)
        return y


class DepthwiseSeparable(paddle.nn.Layer):
    def __init__(
        self,
        num_channels,
        num_filters1,
        num_filters2,
        num_groups,
        stride,
        scale,
        name=None,
    ):
        super().__init__()

        self._depthwise_conv = ConvBNLayer(
            num_channels=num_channels,
            num_filters=int(num_filters1 * scale),
            filter_size=3,
            stride=stride,
            padding=1,
            num_groups=int(num_groups * scale),
            use_cudnn=True,
        )

        self._pointwise_conv = ConvBNLayer(
            num_channels=int(num_filters1 * scale),
            filter_size=1,
            num_filters=int(num_filters2 * scale),
            stride=1,
            padding=0,
        )

    def forward(self, inputs):
        y = self._depthwise_conv(inputs)
        y = self._pointwise_conv(y)
        return y


class MobileNetV1(paddle.nn.Layer):
    def __init__(self, scale=1.0, class_dim=1000):
        super().__init__()
        self.scale = scale
        self.dwsl = []

        self.conv1 = ConvBNLayer(
            num_channels=3,
            filter_size=3,
            channels=3,
            num_filters=int(32 * scale),
            stride=2,
            padding=1,
        )

        dws21 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(32 * scale),
                num_filters1=32,
                num_filters2=64,
                num_groups=32,
                stride=1,
                scale=scale,
            ),
            name="conv2_1",
        )
        self.dwsl.append(dws21)

        dws22 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(64 * scale),
                num_filters1=64,
                num_filters2=128,
                num_groups=64,
                stride=2,
                scale=scale,
            ),
            name="conv2_2",
        )
        self.dwsl.append(dws22)

        dws31 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(128 * scale),
                num_filters1=128,
                num_filters2=128,
                num_groups=128,
                stride=1,
                scale=scale,
            ),
            name="conv3_1",
        )
        self.dwsl.append(dws31)

        dws32 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(128 * scale),
                num_filters1=128,
                num_filters2=256,
                num_groups=128,
                stride=2,
                scale=scale,
            ),
            name="conv3_2",
        )
        self.dwsl.append(dws32)

        dws41 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(256 * scale),
                num_filters1=256,
                num_filters2=256,
                num_groups=256,
                stride=1,
                scale=scale,
            ),
            name="conv4_1",
        )
        self.dwsl.append(dws41)

        dws42 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(256 * scale),
                num_filters1=256,
                num_filters2=512,
                num_groups=256,
                stride=2,
                scale=scale,
            ),
            name="conv4_2",
        )
        self.dwsl.append(dws42)

        for i in range(5):
            tmp = self.add_sublayer(
                sublayer=DepthwiseSeparable(
                    num_channels=int(512 * scale),
                    num_filters1=512,
                    num_filters2=512,
                    num_groups=512,
                    stride=1,
                    scale=scale,
                ),
                name="conv5_" + str(i + 1),
            )
            self.dwsl.append(tmp)

        dws56 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(512 * scale),
                num_filters1=512,
                num_filters2=1024,
                num_groups=512,
                stride=2,
                scale=scale,
            ),
            name="conv5_6",
        )
        self.dwsl.append(dws56)

        dws6 = self.add_sublayer(
            sublayer=DepthwiseSeparable(
                num_channels=int(1024 * scale),
                num_filters1=1024,
                num_filters2=1024,
                num_groups=1024,
                stride=1,
                scale=scale,
            ),
            name="conv6",
        )
        self.dwsl.append(dws6)

        self.pool2d_avg = paddle.nn.AdaptiveAvgPool2D(1)

        self.out = Linear(
            int(1024 * scale),
            class_dim,
            weight_attr=ParamAttr(
                initializer=paddle.nn.initializer.KaimingUniform(),
                name=self.full_name() + "fc7_weights",
            ),
            bias_attr=ParamAttr(name="fc7_offset"),
        )

    def forward(self, inputs):
        y = self.conv1(inputs)
        for dws in self.dwsl:
            y = dws(y)
        y = self.pool2d_avg(y)
        y = paddle.reshape(y, shape=[-1, 1024])
        y = self.out(y)
        return y


class InvertedResidualUnit(paddle.nn.Layer):
    def __init__(
        self,
        num_channels,
        num_in_filter,
        num_filters,
        stride,
        filter_size,
        padding,
        expansion_factor,
    ):
        super().__init__()
        num_expfilter = int(round(num_in_filter * expansion_factor))
        self._expand_conv = ConvBNLayer(
            num_channels=num_channels,
            num_filters=num_expfilter,
            filter_size=1,
            stride=1,
            padding=0,
            act=None,
            num_groups=1,
        )

        self._bottleneck_conv = ConvBNLayer(
            num_channels=num_expfilter,
            num_filters=num_expfilter,
            filter_size=filter_size,
            stride=stride,
            padding=padding,
            num_groups=num_expfilter,
            act=None,
            use_cudnn=True,
        )

        self._linear_conv = ConvBNLayer(
            num_channels=num_expfilter,
            num_filters=num_filters,
            filter_size=1,
            stride=1,
            padding=0,
            act=None,
            num_groups=1,
        )

    def forward(self, inputs, ifshortcut):
        y = self._expand_conv(inputs, if_act=True)
        y = self._bottleneck_conv(y, if_act=True)
        y = self._linear_conv(y, if_act=False)
        if ifshortcut:
            y = paddle.add(inputs, y)
        return y


class InvresiBlocks(paddle.nn.Layer):
    def __init__(self, in_c, t, c, n, s):
        super().__init__()

        self._first_block = InvertedResidualUnit(
            num_channels=in_c,
            num_in_filter=in_c,
            num_filters=c,
            stride=s,
            filter_size=3,
            padding=1,
            expansion_factor=t,
        )

        self._inv_blocks = []
        for i in range(1, n):
            tmp = self.add_sublayer(
                sublayer=InvertedResidualUnit(
                    num_channels=c,
                    num_in_filter=c,
                    num_filters=c,
                    stride=1,
                    filter_size=3,
                    padding=1,
                    expansion_factor=t,
                ),
                name=self.full_name() + "_" + str(i + 1),
            )
            self._inv_blocks.append(tmp)

    def forward(self, inputs):
        y = self._first_block(inputs, ifshortcut=False)
        for inv_block in self._inv_blocks:
            y = inv_block(y, ifshortcut=True)
        return y


class MobileNetV2(paddle.nn.Layer):
    def __init__(self, class_dim=1000, scale=1.0):
        super().__init__()
        self.scale = scale
        self.class_dim = class_dim

        bottleneck_params_list = [
            (1, 16, 1, 1),
            (6, 24, 2, 2),
            (6, 32, 3, 2),
            (6, 64, 4, 2),
            (6, 96, 3, 1),
            (6, 160, 3, 2),
            (6, 320, 1, 1),
        ]

        # 1. conv1
        self._conv1 = ConvBNLayer(
            num_channels=3,
            num_filters=int(32 * scale),
            filter_size=3,
            stride=2,
            act=None,
            padding=1,
        )

        # 2. bottleneck sequences
        self._invl = []
        i = 1
        in_c = int(32 * scale)
        for layer_setting in bottleneck_params_list:
            t, c, n, s = layer_setting
            i += 1
            tmp = self.add_sublayer(
                sublayer=InvresiBlocks(
                    in_c=in_c, t=t, c=int(c * scale), n=n, s=s
                ),
                name='conv' + str(i),
            )
            self._invl.append(tmp)
            in_c = int(c * scale)

        # 3. last_conv
        self._out_c = int(1280 * scale) if scale > 1.0 else 1280
        self._conv9 = ConvBNLayer(
            num_channels=in_c,
            num_filters=self._out_c,
            filter_size=1,
            stride=1,
            act=None,
            padding=0,
        )

        # 4. pool
        self._pool2d_avg = paddle.nn.AdaptiveAvgPool2D(1)

        # 5. fc
        tmp_param = ParamAttr(name=self.full_name() + "fc10_weights")
        self._fc = Linear(
            self._out_c,
            class_dim,
            weight_attr=tmp_param,
            bias_attr=ParamAttr(name="fc10_offset"),
        )

    def forward(self, inputs):
        y = self._conv1(inputs, if_act=True)
        for inv in self._invl:
            y = inv(y)
        y = self._conv9(y, if_act=True)
        y = self._pool2d_avg(y)
        y = paddle.reshape(y, shape=[-1, self._out_c])
        y = self._fc(y)
        return y


def create_optimizer(args, parameter_list):
    optimizer = paddle.optimizer.Momentum(
        learning_rate=args.lr,
        momentum=args.momentum_rate,
        weight_decay=paddle.regularizer.L2Decay(args.l2_decay),
        parameters=parameter_list,
    )

    return optimizer


class FakeDataSet(paddle.io.Dataset):
    def __init__(self, batch_size, label_size, train_steps):
        self.local_random = np.random.RandomState(SEED)
        self.label_size = label_size

        self.imgs = []
        self.labels = []

        self._generate_fake_data(batch_size * (train_steps + 1))

    def _generate_fake_data(self, length):
        for i in range(length):
            img = self.local_random.random_sample([3, 224, 224]).astype(
                'float32'
            )
            label = self.local_random.randint(0, self.label_size, [1]).astype(
                'int64'
            )

            self.imgs.append(img)
            self.labels.append(label)

    def __getitem__(self, idx):
        return [self.imgs[idx], self.labels[idx]]

    def __len__(self):
        return len(self.imgs)


class Args:
    batch_size = 4
    model = "MobileNetV1"
    lr = 0.001
    momentum_rate = 0.99
    l2_decay = 0.1
    num_epochs = 1
    class_dim = 50
    print_step = 1
    train_step = 10
    place = (
        paddle.CUDAPlace(0)
        if paddle.is_compiled_with_cuda()
        else paddle.CPUPlace()
    )
    model_save_dir = None
    model_save_prefix = None
    model_filename = None
    params_filename = None
    dy_state_dict_save_path = None


def train_mobilenet(args, to_static):
    with unique_name.guard():
        np.random.seed(SEED)
        paddle.seed(SEED)
        paddle.framework.random._manual_program_seed(SEED)

        if args.model == "MobileNetV1":
            net = paddle.jit.to_static(
                MobileNetV1(class_dim=args.class_dim, scale=1.0)
            )
        elif args.model == "MobileNetV2":
            net = paddle.jit.to_static(
                MobileNetV2(class_dim=args.class_dim, scale=1.0)
            )
        else:
            print(
                "wrong model name, please try model = MobileNetV1 or MobileNetV2"
            )
            sys.exit()

        optimizer = create_optimizer(args=args, parameter_list=net.parameters())

        # 3. reader
        train_dataset = FakeDataSet(
            args.batch_size, args.class_dim, args.train_step
        )
        BatchSampler = paddle.io.BatchSampler(
            train_dataset, batch_size=args.batch_size
        )
        train_data_loader = paddle.io.DataLoader(
            train_dataset, batch_sampler=BatchSampler
        )

        # 4. train loop
        loss_data = []
        for eop in range(args.num_epochs):
            net.train()
            batch_id = 0
            t_last = 0
            for img, label in train_data_loader():
                t1 = time.time()
                t_start = time.time()
                out = net(img)

                t_end = time.time()
                softmax_out = paddle.nn.functional.softmax(out)
                loss = paddle.nn.functional.cross_entropy(
                    input=softmax_out,
                    label=label,
                    reduction='none',
                    use_softmax=False,
                )
                avg_loss = paddle.mean(x=loss)
                acc_top1 = paddle.static.accuracy(input=out, label=label, k=1)
                acc_top5 = paddle.static.accuracy(input=out, label=label, k=5)
                t_start_back = time.time()

                loss_data.append(avg_loss.numpy())
                avg_loss.backward()
                t_end_back = time.time()
                optimizer.minimize(avg_loss)
                net.clear_gradients()

                t2 = time.time()
                train_batch_elapse = t2 - t1
                if batch_id % args.print_step == 0:
                    print(
                        "epoch id: %d, batch step: %d,  avg_loss %0.5f acc_top1 %0.5f acc_top5 %0.5f %2.4f sec net_t:%2.4f back_t:%2.4f read_t:%2.4f"
                        % (
                            eop,
                            batch_id,
                            avg_loss.numpy(),
                            acc_top1.numpy(),
                            acc_top5.numpy(),
                            train_batch_elapse,
                            t_end - t_start,
                            t_end_back - t_start_back,
                            t1 - t_last,
                        )
                    )
                batch_id += 1
                t_last = time.time()
                if batch_id > args.train_step:
                    # TODO(@xiongkun): open after save / load supported in pir.
                    if to_static and not paddle.base.framework.use_pir_api():
                        paddle.jit.save(net, args.model_save_prefix)
                    else:
                        paddle.save(
                            net.state_dict(),
                            args.dy_state_dict_save_path + '.pdparams',
                        )
                    break

    return np.array(loss_data)


def predict_static(args, data):
    paddle.enable_static()
    exe = base.Executor(args.place)
    # load inference model

    [
        inference_program,
        feed_target_names,
        fetch_targets,
    ] = paddle.static.io.load_inference_model(
        args.model_save_dir,
        executor=exe,
        model_filename=args.model_filename,
        params_filename=args.params_filename,
    )

    pred_res = exe.run(
        inference_program,
        feed={feed_target_names[0]: data},
        fetch_list=fetch_targets,
    )
    paddle.disable_static()
    return pred_res[0]


def predict_dygraph(args, data):
    with enable_to_static_guard(False):
        if args.model == "MobileNetV1":
            model = paddle.jit.to_static(
                MobileNetV1(class_dim=args.class_dim, scale=1.0)
            )
        elif args.model == "MobileNetV2":
            model = paddle.jit.to_static(
                MobileNetV2(class_dim=args.class_dim, scale=1.0)
            )
        # load dygraph trained parameters
        model_dict = paddle.load(args.dy_state_dict_save_path + '.pdparams')
        model.set_dict(model_dict)
        model.eval()

        pred_res = model(base.dygraph.to_variable(data))

        return pred_res.numpy()


def predict_dygraph_jit(args, data):
    model = paddle.jit.load(args.model_save_prefix)
    model.eval()

    pred_res = model(data)

    return pred_res.numpy()


def predict_analysis_inference(args, data):
    output = PredictorTools(
        args.model_save_dir, args.model_filename, args.params_filename, [data]
    )
    (out,) = output()
    return out


class TestMobileNet(Dy2StTestBase):
    def setUp(self):
        self.args = Args()
        self.temp_dir = tempfile.TemporaryDirectory()
        self.args.model_save_dir = os.path.join(
            self.temp_dir.name, "./inference"
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def train(self, model_name, to_static):
        self.args.model = model_name
        self.args.model_save_prefix = os.path.join(
            self.temp_dir.name, "./inference/" + model_name
        )
        self.args.model_filename = model_name + INFER_MODEL_SUFFIX
        self.args.params_filename = model_name + INFER_PARAMS_SUFFIX
        self.args.dy_state_dict_save_path = os.path.join(
            self.temp_dir.name, model_name + ".dygraph"
        )
        with enable_to_static_guard(to_static):
            out = train_mobilenet(self.args, to_static)
        return out

    def assert_same_loss(self, model_name):
        dy_out = self.train(model_name, to_static=False)
        st_out = self.train(model_name, to_static=True)
        np.testing.assert_allclose(
            dy_out,
            st_out,
            rtol=1e-05,
            err_msg=f'dy_out: {dy_out}, st_out: {st_out}',
        )

    def assert_same_predict(self, model_name):
        self.args.model = model_name
        self.args.model_save_prefix = os.path.join(
            self.temp_dir.name, "./inference/" + model_name
        )
        self.args.model_filename = model_name + INFER_MODEL_SUFFIX
        self.args.params_filename = model_name + INFER_PARAMS_SUFFIX
        self.args.dy_state_dict_save_path = os.path.join(
            self.temp_dir.name, model_name + ".dygraph"
        )
        local_random = np.random.RandomState(SEED)
        image = local_random.random_sample([1, 3, 224, 224]).astype('float32')
        dy_pre = predict_dygraph(self.args, image)
        st_pre = predict_static(self.args, image)
        dy_jit_pre = predict_dygraph_jit(self.args, image)
        predictor_pre = predict_analysis_inference(self.args, image)
        np.testing.assert_allclose(
            dy_pre,
            st_pre,
            rtol=1e-05,
            err_msg=f'dy_pre:\n {dy_pre}\n, st_pre: \n{st_pre}.',
        )
        np.testing.assert_allclose(
            dy_jit_pre,
            st_pre,
            rtol=1e-05,
            err_msg=f'dy_jit_pre:\n {dy_jit_pre}\n, st_pre: \n{st_pre}.',
        )
        np.testing.assert_allclose(
            predictor_pre,
            st_pre,
            rtol=1e-05,
            atol=1e-05,
            err_msg=f'inference_pred_res:\n {predictor_pre}\n, st_pre: \n{st_pre}.',
        )

    @test_legacy_and_pir
    def test_mobile_net(self):
        # MobileNet-V1
        self.assert_same_loss("MobileNetV1")
        # MobileNet-V2
        self.assert_same_loss("MobileNetV2")

        # TODO(@xiongkun): open after save / load supported in pir.
        if not paddle.base.framework.use_pir_api():
            self.verify_predict()

    def verify_predict(self):
        # MobileNet-V1
        self.assert_same_predict("MobileNetV1")
        # MobileNet-V2
        self.assert_same_predict("MobileNetV2")


if __name__ == '__main__':
    unittest.main()
