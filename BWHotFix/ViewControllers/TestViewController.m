//
//  TestViewController.m
//  BWHotFix
//
//  Created by bairdweng on 2020/11/5.
//

#import "TestViewController.h"

@interface TestViewController ()<UITableViewDelegate,UITableViewDataSource>

@property(nonatomic, copy)NSString *showText;
@property(nonatomic, weak)UITableView *dataTableView;
@end

@implementation TestViewController


static NSString *cellID = @"test_cell_id";

- (void)viewDidLoad {
    [super viewDidLoad];
    self.showText = @"show text";
    
    UITableView *tableView = [[UITableView alloc]initWithFrame:self.view.bounds];
    tableView.delegate = self;
    tableView.dataSource = self;
    [tableView registerClass:UITableViewCell.self forCellReuseIdentifier:cellID];
    [self.view addSubview: tableView];
  
    
    // Do any additional setup after loading the view.
}

-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID forIndexPath:indexPath];
    cell.textLabel.text = @"hello";
    return cell;
}

-(NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return  10;
}

- (NSInteger)tableView:(nonnull UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return  1;
}

-(void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

-(CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 60;
}

@end
